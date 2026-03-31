# gen_batch_server

[![CI](https://github.com/rabbitmq/gen-batch-server/actions/workflows/ci.yaml/badge.svg)](https://github.com/rabbitmq/gen-batch-server/actions/workflows/ci.yaml)


A generic batching server for erlang / elixir


`gen_batch_server` is a stateful generic server similar to [`gen_server`](https://erlang.org/doc/man/gen_server.html) that instead of processing incoming requests
one by one gathers them into batches before they are passed to the behaviour
implementation.

Batches are processed _either_ when the Erlang process mailbox has no further
messages to batch _or_
when the number of messages in the current batch reaches the maximum batch size
limit.
`gen_batch_server` tries to trade latency for throughput by automatically growing the max batch
size limit when message ingress is high and shrinks it down again as ingress
reduces.

This behaviour makes it suitable for use as a data sink, proxy or other kinds of
aggregator that benefit from processing messages in batches. Examples
would be a log writer that needs to flush messages to disk using `file:sync/1`
without undue delay or a metrics sink that aggregates metrics from multiple
processes and writes them to an external service. It could also be beneficial
to use `gen_batch_server` to proxy a bunch of processes that want to update
some resource (such as a `dets` table) that doesn't handle casts.

## Usage

#### start_link(Name, Mod, Args) -> Result
#### start_link(Name, Mod, Args, Opts) -> Result

    Types:
        Name = {local,Name} | {global,GlobalName} | {via,Module,ViaName}
        Mod = module()
        Args = term()
        Opt = {debug, Dbgs} |
              {min_batch_size | max_batch_size, non_neg_integer()} |
              {reversed_batch, boolean()} |
              {flush_mailbox_on_terminate, false | {true, SummaryCount}} |
              {batch_size_growth, exponential | {aimd, Step}}
        SummaryCount = non_neg_integer()
        Step = pos_integer()
        Opts = [Opt]
        Opts = [term()]
        Result = {ok,Pid} | ignore | {error,Error}

Creates a `gen_batch_server` as part of a supervision tree. The minimum and
maximum batch sizes that control the bounds of the batch sizes that are processed
can be controlled using the `min_batch_size` (default: 32)
and `max_batch_size` (default: 8192) options.

The `reversed_batch` option is an advanced option that where the batch that is
passed to `handle_batch/2` is in reversed order to the one the messages were
received in. This avoids a `list:reverse/1` all before the batch handling and is
somewhat more performant.

The `flush_mailbox_on_terminate` option controls whether pending mailbox messages
are drained when the server terminates. By default it is `false` (disabled). When
set to `{true, SummaryCount}`, up to `SummaryCount` of the pending messages are
captured along with the total mailbox count and written to the process dictionary
under the key `mailbox_summary` (as `#{total => Count, messages => [...]}`). The
mailbox is then fully drained. This happens *before* `Module:terminate/2` is called,
so the callback can inspect or forward the summary. Draining the mailbox prevents
`proc_lib` crash reports from pretty-printing potentially large messages (e.g. binary
payloads), which can cause unbounded memory growth.

The `batch_size_growth` option controls how the batch size grows when the server
is under load. The default, `exponential`, doubles the batch size each time a full
batch is completed (the original behaviour). Setting it to `{aimd, Step}` switches
to Additive Increase / Multiplicative Decrease: the batch size grows by `Step` on
each full batch and halves whenever the mailbox is found empty. AIMD produces a
smoother, more gradual ramp-up and is useful when large sudden jumps in batch size
are undesirable.


#### cast(ServerRef, Request) -> ok

    Types:
        ServerRef = pid() | {Name :: atom(), node()} | Name :: atom()
        Request = term()

Sends an asynchronous request to the `gen_batch_server returning` `ok` immediately.
The request tuple (`{cast, Request}`) is included in the list of operations passed
to `Module:handle_batch/2`.

#### cast_batch(ServerRef, Batch) -> ok

    Types:
        ServerRef = pid() | {Name :: atom(), node()} | Name :: atom()
        Batch = [term()]

Sends an asynchronous batch of requests to the `gen_batch_server returning` `ok`
immediately. The batch is appended in order to the current gen_batch_server batch.

#### call(ServerRef, Request) -> Reply
#### call(ServerRef, Request, Timeout) -> Reply

    Types:
        ServerRef = pid() | {Name :: atom(), node()} | Name :: atom()
        Request = term()
        Reply = term()
        Timeout = non_neg_integer() | infinity.

Makes a synchronous call to the `gen_batch_server` and waits for the response provided
by `Module:handle_batch/2`.
The timeout is optional and defaults to 5000ms.

#### send_request(ServerRef, Request) -> ReqId

    Types:
        ServerRef = pid() | {Name :: atom(), node()} | Name :: atom()
        Request = term()
        ReqId = request_id()

Sends an asynchronous call request to the `gen_batch_server`. Returns a request
identifier `ReqId` that can be used with `wait_response/2`, `receive_response/2`,
or `check_response/2` to collect the reply later. The request appears as a
`{call, From, Request}` operation in `Module:handle_batch/2`.

#### send_request(ServerRef, Request, Label, ReqIdCollection) -> NewReqIdCollection

    Types:
        ServerRef = pid() | {Name :: atom(), node()} | Name :: atom()
        Request = term()
        Label = term()
        ReqIdCollection = request_id_collection()
        NewReqIdCollection = request_id_collection()

Like `send_request/2`, but stores the request identifier in a collection
associated with `Label`. The collection can later be passed to
`receive_response/3`, `wait_response/3`, or `check_response/3`.

#### wait_response(ReqId, WaitTime) -> Result
#### receive_response(ReqId, Timeout) -> Result

    Types:
        ReqId = request_id()
        WaitTime = Timeout = timeout() | {abs, integer()}
        Result = {reply, Reply} | {error, {Reason, ServerRef}} | timeout

Wait for a response to an async request made with `send_request/2`.
`receive_response` abandons the request on timeout (late replies are dropped),
while `wait_response` keeps the monitor so you can retry.

#### wait_response(ReqIdCollection, WaitTime, Delete) -> Result
#### receive_response(ReqIdCollection, Timeout, Delete) -> Result

    Types:
        ReqIdCollection = request_id_collection()
        WaitTime = Timeout = timeout() | {abs, integer()}
        Delete = boolean()
        Result = {Response, Label, NewReqIdCollection} | no_request | timeout
        Response = {reply, Reply} | {error, {Reason, ServerRef}}

Collection variants. Returns the response along with the `Label` associated
with the request and an updated collection.

#### check_response(Msg, ReqId) -> Result

    Types:
        Msg = term()
        ReqId = request_id()
        Result = {reply, Reply} | {error, {Reason, ServerRef}} | no_reply

Check whether a received message `Msg` is a response to the request `ReqId`.
Returns `no_reply` if the message does not correspond to this request.

#### check_response(Msg, ReqIdCollection, Delete) -> Result

    Types:
        Msg = term()
        ReqIdCollection = request_id_collection()
        Delete = boolean()
        Result = {Response, Label, NewReqIdCollection} | no_request | no_reply
        Response = {reply, Reply} | {error, {Reason, ServerRef}}

Collection variant of `check_response/2`.

#### reqids_new() -> NewReqIdCollection

Creates a new empty request identifier collection.

#### reqids_add(ReqId, Label, ReqIdCollection) -> NewReqIdCollection

Stores `ReqId` with an associated `Label` in the collection.

#### reqids_size(ReqIdCollection) -> non_neg_integer()

Returns the number of request identifiers in the collection.

#### reqids_to_list(ReqIdCollection) -> [{ReqId, Label}]

Converts the collection to a list of `{ReqId, Label}` pairs.

#### Module:init(Args) -> Result

    Types:
        Args = term()
        Result = {ok, State} |
                 {ok, State, {continue, Continue}} |
                 ignore |
                 {stop, Reason}
        State = term()
        Continue = term()
        Reason = term()

Called whenever a `gen_batch_server` is started with the arguments provided
to `start_link/4`.

Returning `{ok, State, {continue, Continue}}` will cause `handle_continue/2`
to be called before processing any messages.

Returning `ignore` will cause `start_link` to return `ignore` and the process
will exit normally without a crash report.

Can be used in scenarios where a `gen_batch_server`
depends on a resource that can be temporarily
unavailable (e.g. when a Ra member runs out of disk space).

#### Module:handle_batch(Batch, State) -> Result.

    Types:
        Batch = [Op]
        UserOp = term(),
        Op = {cast, UserOp} |
             {call, from(), UserOp} |
             {info, UserOp}.
        Result = {ok, State} |
                 {ok, State, {continue, Continue}} |
                 {ok, Actions, State} |
                 {ok, Actions, State, {continue, Continue}} |
                 {stop, Reason}
        State = term()
        From = {Pid :: pid(), Tag :: reference()}
        Action = {reply, From, Msg} | garbage_collect
        Actions = [Action]
        Reason = term()

Called whenever a new batch is ready for processing. The implementation can
optionally return a list of reply actions used to reply to `call` operations.

#### Module:handle_continue(Continue, State) -> Result

    Types:
        Continue = term()
        State = term()
        Result = {ok, NewState} |
                 {ok, NewState, {continue, NewContinue}} |
                 {stop, Reason}
        NewState = term()
        NewContinue = term()
        Reason = term()

Optional. Called after `init/1` returns `{ok, State, {continue, Continue}}` or
after `handle_batch/2` returns with a `{continue, Continue}` tuple.

Most useful for post-`init/2` work that needs
the server to be registered first.

#### Module:terminate(Reason, State) -> Result

    Types:
        Reason = term()
        Result = term()
        State = term(),


Optional. Called whenever a `gen_batch_server` is terminating.

#### Module:format_status(State) -> Result

    Types:
        Result = term()
        State = term(),


Optional. Used to provide a custom formatting of the user state.


# Copyright

(c) 2018-2026 Broadcom. All Rights Reserved. The term Broadcom refers to Broadcom Inc. and/or its subsidiaries.
