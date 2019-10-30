# gen_batch_server

[![Build Status](https://travis-ci.org/rabbitmq/gen-batch-server.svg?branch=master)](https://travis-ci.org/rabbitmq/gen-batch-server)


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
              {reversed_batch, boolean()}
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
        Op = {cast, UserOp} |
             {call, from(), UserOp} |
             {info, UserOp}.
        Result = {ok, State} | {ok, Actions, State} | {stop, Reason}
        State = term()
        From = {Pid :: pid(), Tag :: reference()}
        Action = {reply, From, Msg} | garbage_collect
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

