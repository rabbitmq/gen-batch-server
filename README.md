# gen_batch_server

A generic batching server for erlang / elixir


`gen_batch_server` is a stateful generic server similar to [`gen_server`](http://erlang.org/doc/man/gen_server.html) that instead of processing incoming requests
one by one gathers them into batches before the are passed to the behaviour
implementation.

Batches are processed _either_ when the erlang process mailbox has no further
messages to batch _or_
when the number of messages in the current batch reaches the maximum batch size
limit.
`gen_batch_server` tries to trade latency for throughput by automatically growing the max batch
size limit when message ingress is high and shrinks it down again as ingress
reduces.

This behaviour makes it suitable for use as a data sink, proxy or other
kind of aggregator that benefit from processing messages in batches. Examples
would be a log writer that needs to flush messages to disk using `file:sync/1`
without undue delay or a metrics sink that aggregates metrics from multiple
processes and writes them to an external service. It could also be beneficial
to use `gen_batch_server` to proxy a bunch processes that want to update
some resource (such as a `dets` table) that doesn't handle casts.

## Usage

#### start_link(Name, Mod, Args) -> Result
#### start_link(Name, Mod, Args, Opts) -> Result

    Types:
        Name = {local,Name} | {global,GlobalName} | {via,Module,ViaName}
        Mod = module()
        Args = term()
        Opt = {debug, Dbgs}
        Opts = [Opt]
        Opts = [term()]
        Result = {ok,Pid} | ignore | {error,Error}

Creates a `gen_batch_server` as part of a supervision tree.


#### cast(ServerRef, Request) -> ok

    Types:
        ServerRef = pid() | {Name :: atom(), node()} | Name :: atom()
        Request = term()

Sends an asynchronous request to the `gen_batch_server returning` `ok` immediately.
The `pid` of the calling process will be captured and included in the
request tuple (`{cast, Pid, Request}`) included in the list of operations
passed to `Module:handle_batch/2`.


#### call(ServerRef, Request) -> Reply
#### call(ServerRef, Request, Timeout) -> Reply

    Types:
        ServerRef = pid() | {Name :: atom(), node()} | Name :: atom()
        Request = term()
        Reply = term()
        Timeout = non_neg_integer() | infinity.

Sends an synchronous request to the `gen_batch_server returning` returning the
response provided for the operation by `Module:handle_batch/2`. The timeout
is optional and defaults to 5000ms.

#### Module:init(Args) -> Result

    Types:
        Args = term()
        Result = {ok, State} | {stop, Reason}
        State = term(),
        Reason = term()


Called whenever a `gen_batch_server` is started with the arguments provided
to `start_link/4`.

#### Module:handle_batch(Batch, State) -> Result.

    Types:
        Batch = [Op]
        UserOp = term(),
        Op = {cast, pid(), UserOp} |
             {call, from(), UserOp} |
             {info, UserOp}.
        Result = {ok, State} | {ok, Actions, State} | {stop, Reason}
        State = term()
        From = {Pid :: pid(), Tag :: reference()}
        Action = {reply, From, Msg}
        Actions = [Action]
        Reason = term()

Called whenever a new batch is ready for processing. The implementation can
optionally return a list of reply actions used to reply to `call` operations.

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

(c) Pivotal Software Inc., 2018-Present.

