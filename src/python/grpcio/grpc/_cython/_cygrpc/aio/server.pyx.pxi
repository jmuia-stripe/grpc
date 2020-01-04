# Copyright 2019 The gRPC Authors
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.


import inspect
import traceback


# TODO(https://github.com/grpc/grpc/issues/20850) refactor this.
_LOGGER = logging.getLogger(__name__)
cdef int _EMPTY_FLAG = 0


cdef class _HandlerCallDetails:
    def __cinit__(self, str method, tuple invocation_metadata):
        self.method = method
        self.invocation_metadata = invocation_metadata


cdef class RPCState:

    def __cinit__(self, AioServer server):
        self.call = NULL
        self.server = server
        grpc_metadata_array_init(&self.request_metadata)
        grpc_call_details_init(&self.details)
        self.abort_exception = None
        self.metadata_sent = False
        self.status_sent = False

    cdef bytes method(self):
      return _slice_bytes(self.details.method)

    def __dealloc__(self):
        """Cleans the Core objects."""
        grpc_call_details_destroy(&self.details)
        grpc_metadata_array_destroy(&self.request_metadata)
        if self.call:
            grpc_call_unref(self.call)


# TODO(lidiz) inherit this from Python level `AioRpcStatus`, we need to improve
# current code structure to make it happen.
class AbortError(Exception): pass


def _raise_if_aborted(RPCState rpc_state):
    """Raise AbortError if RPC is aborted.

    Server method handlers may suppress the abort exception. We need to halt
    the RPC execution in that case. This function needs to be called after
    running application code.
    """
    if rpc_state.abort_exception is not None:
        raise rpc_state.abort_exception


async def _perform_abort(RPCState rpc_state,
                         grpc_status_code code,
                         str details, 
                         tuple trailing_metadata,
                         object loop):
    """Perform the abort logic.

    Sends final status to the client, and then set the RPC into corresponding
    state.
    """
    if rpc_state.abort_exception is not None:
        raise RuntimeError('Abort already called!')
    else:
        # Keeps track of the exception object. After abort happen, the RPC
        # should stop execution. However, if users decided to suppress it, it
        # could lead to undefined behavior.
        rpc_state.abort_exception = AbortError('Locally aborted.')

    rpc_state.status_sent = True
    await _send_error_status_from_server(
        rpc_state,
        code,
        details,
        trailing_metadata,
        rpc_state.metadata_sent,
        loop
    )


cdef class _ServicerContext:
    cdef RPCState _rpc_state
    cdef object _loop
    cdef object _request_deserializer
    cdef object _response_serializer

    def __cinit__(self,
                  RPCState rpc_state,
                  object request_deserializer,
                  object response_serializer,
                  object loop):
        self._rpc_state = rpc_state
        self._request_deserializer = request_deserializer
        self._response_serializer = response_serializer
        self._loop = loop

    async def read(self):
        if self._rpc_state.status_sent:
            raise RuntimeError('RPC already finished.')
        cdef bytes raw_message = await _receive_message(self._rpc_state, self._loop)
        return deserialize(self._request_deserializer,
                           raw_message)

    async def write(self, object message):
        if self._rpc_state.status_sent:
            raise RuntimeError('RPC already finished.')
        await _send_message(self._rpc_state,
                            serialize(self._response_serializer, message),
                            self._rpc_state.metadata_sent,
                            self._loop)
        if not self._rpc_state.metadata_sent:
            self._rpc_state.metadata_sent = True

    async def send_initial_metadata(self, tuple metadata):
        if self._rpc_state.status_sent:
            raise RuntimeError('RPC already finished.')
        elif self._rpc_state.metadata_sent:
            raise RuntimeError('Send initial metadata failed: already sent')
        else:
            _send_initial_metadata(self._rpc_state, self._loop)
            self._rpc_state.metadata_sent = True

    async def abort(self,
              object code,
              str details='',
              tuple trailing_metadata=_EMPTY_METADATA):
        await _perform_abort(
            self._rpc_state,
            code.value[0],
            details,
            trailing_metadata,
            self._loop
        )

        raise self._rpc_state.abort_exception


cdef _find_method_handler(str method, list generic_handlers):
    # TODO(lidiz) connects Metadata to call details
    cdef _HandlerCallDetails handler_call_details = _HandlerCallDetails(method,
                                                                        None)

    for generic_handler in generic_handlers:
        method_handler = generic_handler.service(handler_call_details)
        if method_handler is not None:
            return method_handler
    return None


async def _handle_unary_unary_rpc(object method_handler,
                                  RPCState rpc_state,
                                  object loop):
    # Receives request message
    cdef bytes request_raw = await _receive_message(rpc_state, loop)

    # Deserializes the request message
    cdef object request_message = deserialize(
        method_handler.request_deserializer,
        request_raw,
    )

    # Executes application logic
    cdef object response_message = await method_handler.unary_unary(
        request_message,
        _ServicerContext(
            rpc_state,
            None,
            None,
            loop,
        ),
    )

    # Raises exception if aborted
    _raise_if_aborted(rpc_state)

    # Serializes the response message
    cdef bytes response_raw = serialize(
        method_handler.response_serializer,
        response_message,
    )

    # Sends response message
    cdef tuple send_ops = (
        SendStatusFromServerOperation(
            tuple(),
            StatusCode.ok,
            b'',
            _EMPTY_FLAGS,
        ),
        SendInitialMetadataOperation(None, _EMPTY_FLAGS),
        SendMessageOperation(response_raw, _EMPTY_FLAGS),
    )
    await execute_batch(rpc_state, send_ops, loop)
    rpc_state.status_sent = True


async def _handle_unary_stream_rpc(object method_handler,
                                   RPCState rpc_state,
                                   object loop):
    # Receives request message
    cdef bytes request_raw = await _receive_message(rpc_state, loop)

    # Deserializes the request message
    cdef object request_message = deserialize(
        method_handler.request_deserializer,
        request_raw,
    )

    cdef _ServicerContext servicer_context = _ServicerContext(
        rpc_state,
        method_handler.request_deserializer,
        method_handler.response_serializer,
        loop,
    )

    cdef object async_response_generator
    cdef object response_message
    if inspect.iscoroutinefunction(method_handler.unary_stream):
        # The handler uses reader / writer API, returns None.
        await method_handler.unary_stream(
            request_message,
            servicer_context,
        )

        # Raises exception if aborted
        _raise_if_aborted(rpc_state)
    else:
        # The handler uses async generator API
        async_response_generator = method_handler.unary_stream(
            request_message,
            servicer_context,
        )

        # Consumes messages from the generator
        async for response_message in async_response_generator:
            # Raises exception if aborted
            _raise_if_aborted(rpc_state)

            if rpc_state.server._status == AIO_SERVER_STATUS_STOPPED:
                # The async generator might yield much much later after the
                # server is destroied. If we proceed, Core will crash badly.
                _LOGGER.info('Aborting RPC due to server stop.')
                return
            else:
                await servicer_context.write(response_message)

    # Sends the final status of this RPC
    cdef SendStatusFromServerOperation op = SendStatusFromServerOperation(
        None,
        StatusCode.ok,
        b'',
        _EMPTY_FLAGS,
    )

    cdef tuple ops = (op,)
    await execute_batch(rpc_state, ops, loop)
    rpc_state.status_sent = True


async def _handle_exceptions(RPCState rpc_state, object rpc_coro, object loop):
    try:
        try:
            await rpc_coro
        except AbortError as e:
            # Caught AbortError check if it is the same one
            assert rpc_state.abort_exception is e, 'Abort error has been replaced!'
            return
        else:
            # Check if the abort exception got suppressed
            if rpc_state.abort_exception is not None:
                _LOGGER.error(
                    'Abort error unexpectedly suppressed: %s',
                    traceback.format_exception(rpc_state.abort_exception)
                )
    except Exception as e:
        _LOGGER.exception(e)
        if not rpc_state.status_sent and rpc_state.server._status != AIO_SERVER_STATUS_STOPPED:
            await _perform_abort(
                rpc_state,
                StatusCode.unknown,
                '%s: %s' % (type(e), e),
                _EMPTY_METADATA,
                loop
            )


async def _handle_cancellation_from_core(object rpc_task,
                                         RPCState rpc_state,
                                         object loop):
    cdef ReceiveCloseOnServerOperation op = ReceiveCloseOnServerOperation(_EMPTY_FLAG)
    cdef tuple ops = (op,)

    # Awaits cancellation from peer.
    await execute_batch(rpc_state, ops, loop)
    if op.cancelled() and not rpc_task.done():
        # Injects `CancelledError` to halt the RPC coroutine
        rpc_task.cancel()


async def _schedule_rpc_coro(object rpc_coro,
                             RPCState rpc_state,
                             object loop):
    # Schedules the RPC coroutine.
    cdef object rpc_task = loop.create_task(_handle_exceptions(
        rpc_state,
        rpc_coro,
        loop,
    ))
    await _handle_cancellation_from_core(rpc_task, rpc_state, loop)


async def _handle_rpc(list generic_handlers, RPCState rpc_state, object loop):
    # Finds the method handler (application logic)
    cdef object method_handler = _find_method_handler(
        rpc_state.method().decode(),
        generic_handlers,
    )
    if method_handler is None:
        await _perform_abort(
            rpc_state,
            StatusCode.unimplemented,
            b'Method not found!',
            _EMPTY_METADATA,
            loop
        )
        return

    # TODO(lidiz) extend to all 4 types of RPC
    if not method_handler.request_streaming and method_handler.response_streaming:
        try:
            await _handle_unary_stream_rpc(method_handler,
                                        rpc_state,
                                        loop)
        except Exception as e:
            raise
    elif not method_handler.request_streaming and not method_handler.response_streaming:
        await _handle_unary_unary_rpc(method_handler,
                                      rpc_state,
                                      loop)
    else:
        raise NotImplementedError()


class _RequestCallError(Exception): pass

cdef CallbackFailureHandler REQUEST_CALL_FAILURE_HANDLER = CallbackFailureHandler(
    'grpc_server_request_call', None, _RequestCallError)


cdef CallbackFailureHandler SERVER_SHUTDOWN_FAILURE_HANDLER = CallbackFailureHandler(
    'grpc_server_shutdown_and_notify',
    None,
    RuntimeError)


cdef class AioServer:

    def __init__(self, loop, thread_pool, generic_handlers, interceptors,
                 options, maximum_concurrent_rpcs, compression):
        # NOTE(lidiz) Core objects won't be deallocated automatically.
        # If AioServer.shutdown is not called, those objects will leak.
        self._server = Server(options)
        self._cq = CallbackCompletionQueue()
        grpc_server_register_completion_queue(
            self._server.c_server,
            self._cq.c_ptr(),
            NULL
        )

        self._loop = loop
        self._status = AIO_SERVER_STATUS_READY
        self._generic_handlers = []
        self.add_generic_rpc_handlers(generic_handlers)
        self._serving_task = None
        self._ongoing_rpc_tasks = set()

        self._shutdown_lock = asyncio.Lock(loop=self._loop)
        self._shutdown_completed = self._loop.create_future()
        self._shutdown_callback_wrapper = CallbackWrapper(
            self._shutdown_completed,
            SERVER_SHUTDOWN_FAILURE_HANDLER)
        self._crash_exception = None

        if interceptors:
            raise NotImplementedError()
        if maximum_concurrent_rpcs:
            raise NotImplementedError()
        if compression:
            raise NotImplementedError()
        if thread_pool:
            raise NotImplementedError()

    def add_generic_rpc_handlers(self, generic_rpc_handlers):
        for h in generic_rpc_handlers:
            self._generic_handlers.append(h)

    def add_insecure_port(self, address):
        return self._server.add_http2_port(address)

    def add_secure_port(self, address, server_credentials):
        return self._server.add_http2_port(address,
                                          server_credentials._credentials)

    async def _request_call(self):
        cdef grpc_call_error error
        cdef RPCState rpc_state = RPCState(self)
        cdef object future = self._loop.create_future()
        cdef CallbackWrapper wrapper = CallbackWrapper(
            future,
            REQUEST_CALL_FAILURE_HANDLER)
        # NOTE(lidiz) Without Py_INCREF, the wrapper object will be destructed
        # when calling "await". This is an over-optimization by Cython.
        cpython.Py_INCREF(wrapper)
        error = grpc_server_request_call(
            self._server.c_server, &rpc_state.call, &rpc_state.details,
            &rpc_state.request_metadata,
            self._cq.c_ptr(), self._cq.c_ptr(),
            wrapper.c_functor()
        )
        if error != GRPC_CALL_OK:
            raise RuntimeError("Error in grpc_server_request_call: %s" % error)

        await future
        cpython.Py_DECREF(wrapper)
        return rpc_state

    async def _server_main_loop(self,
                                object server_started):
        self._server.start()
        cdef RPCState rpc_state
        server_started.set_result(True)

        while True:
            # When shutdown begins, no more new connections.
            if self._status != AIO_SERVER_STATUS_RUNNING:
                break

            # Accepts new request from Core
            rpc_state = await self._request_call()

            # Creates the dedicated RPC coroutine. If we schedule it right now,
            # there is no guarantee if the cancellation listening coroutine is
            # ready or not. So, we should control the ordering by scheduling
            # the coroutine onto event loop inside of the cancellation
            # coroutine.
            rpc_coro = _handle_rpc(self._generic_handlers,
                                   rpc_state,
                                   self._loop)

            # Fires off a task that listens on the cancellation from client.
            self._loop.create_task(
                _schedule_rpc_coro(
                    rpc_coro,
                    rpc_state,
                    self._loop
                )
            )

    def _serving_task_crash_handler(self, object task):
        """Shutdown the server immediately if unexpectedly exited."""
        if task.exception() is None:
            return
        if self._status != AIO_SERVER_STATUS_STOPPING:
            self._crash_exception = task.exception()
            _LOGGER.exception(self._crash_exception)
            self._loop.create_task(self.shutdown(None))

    async def start(self):
        if self._status == AIO_SERVER_STATUS_RUNNING:
            return
        elif self._status != AIO_SERVER_STATUS_READY:
            raise RuntimeError('Server not in ready state')

        self._status = AIO_SERVER_STATUS_RUNNING
        cdef object server_started = self._loop.create_future()
        self._serving_task = self._loop.create_task(self._server_main_loop(server_started))
        self._serving_task.add_done_callback(self._serving_task_crash_handler)
        # Needs to explicitly wait for the server to start up.
        # Otherwise, the actual start time of the server is un-controllable.
        await server_started

    async def _start_shutting_down(self):
        """Prepares the server to shutting down.

        This coroutine function is NOT coroutine-safe.
        """
        # The shutdown callback won't be called until there is no live RPC.
        grpc_server_shutdown_and_notify(
            self._server.c_server,
            self._cq._cq,
            self._shutdown_callback_wrapper.c_functor())

        # Ensures the serving task (coroutine) exits.
        try:
            await self._serving_task
        except _RequestCallError:
            pass

    async def shutdown(self, grace):
        """Gracefully shutdown the Core server.

        Application should only call shutdown once.

        Args:
          grace: An optional float indicating the length of grace period in
            seconds.
        """
        if self._status == AIO_SERVER_STATUS_READY or self._status == AIO_SERVER_STATUS_STOPPED:
            return

        async with self._shutdown_lock:
            if self._status == AIO_SERVER_STATUS_RUNNING:
                self._server.is_shutting_down = True
                self._status = AIO_SERVER_STATUS_STOPPING
                await self._start_shutting_down()

        if grace is None:
            # Directly cancels all calls
            grpc_server_cancel_all_calls(self._server.c_server)
            await self._shutdown_completed
        else:
            try:
                await asyncio.wait_for(
                    asyncio.shield(
                        self._shutdown_completed,
                        loop=self._loop
                    ),
                    grace,
                    loop=self._loop,
                )
            except asyncio.TimeoutError:
                # Cancels all ongoing calls by the end of grace period.
                grpc_server_cancel_all_calls(self._server.c_server)
                await self._shutdown_completed

        async with self._shutdown_lock:
            if self._status == AIO_SERVER_STATUS_STOPPING:
                grpc_server_destroy(self._server.c_server)
                self._server.c_server = NULL
                self._server.is_shutdown = True
                self._status = AIO_SERVER_STATUS_STOPPED

                # Shuts down the completion queue
                await self._cq.shutdown()
    
    async def wait_for_termination(self, object timeout):
        if timeout is None:
            await self._shutdown_completed
        else:
            try:
                await asyncio.wait_for(
                    asyncio.shield(
                        self._shutdown_completed,
                        loop=self._loop,
                    ),
                    timeout,
                    loop=self._loop,
                )
            except asyncio.TimeoutError:
                if self._crash_exception is not None:
                    raise self._crash_exception
                return False
        if self._crash_exception is not None:
            raise self._crash_exception
        return True

    def __dealloc__(self):
        """Deallocation of Core objects are ensured by Python grpc.aio.Server.

        If the Cython representation is deallocated without underlying objects
        freed, raise an RuntimeError.
        """
        # TODO(lidiz) if users create server, and then dealloc it immediately.
        # There is a potential memory leak of created Core server.
        if self._status != AIO_SERVER_STATUS_STOPPED:
            _LOGGER.warning(
                '__dealloc__ called on running server %s with status %d',
                self,
                self._status
            )
