%% This Source Code Form is subject to the terms of the Mozilla Public
%% License, v. 2.0. If a copy of the MPL was not distributed with this
%% file, You can obtain one at https://mozilla.org/MPL/2.0/.
%%
%% Copyright (c) 2018-2023 Broadcom. All Rights Reserved. The term Broadcom refers to Broadcom Inc. and/or its subsidiaries.
%%
-module(gen_batch_server).
-export([start_link/2,
         start_link/3,
         start_link/4,
         init_it/6,
         stop/1,
         stop/3,
         cast/2,
         cast_batch/2,
         call/2,
         call/3,
         send_request/2,
         send_request/4,
         wait_response/2,
         wait_response/3,
         receive_response/2,
         receive_response/3,
         check_response/2,
         check_response/3,
         reqids_new/0,
         reqids_add/3,
         reqids_size/1,
         reqids_to_list/1,
         system_continue/3,
         system_terminate/4,
         system_get_state/1,
         write_debug/3,
         format_status/2,
         %% needed for hibernation
         loop_wait/2
        ]).

-define(MIN_MAX_BATCH_SIZE, 32).
-define(MAX_MAX_BATCH_SIZE, 8192).

-type server_ref() :: pid() |
                      (LocalName :: atom()) |
                      {Name :: atom(), Node :: atom()} |
                      {'global', term()} |
                      {'via', Module :: module(), Name :: term()}.

-type reply_tag() :: reference()
                   | nonempty_improper_list('alias', reference()).

-type from() :: {Pid :: pid(), Tag :: reply_tag()}.

-opaque request_id() :: gen:request_id().

-opaque request_id_collection() :: gen:request_id_collection().

-type response_timeout() :: timeout() | {abs, integer()}.

-type batch() :: [op()] | {batch, term()}.

-type op() :: {cast, UserOp :: term()} |
              {call, from(), UserOp :: term()} |
              {info, UserOp :: term()}.

-record(config, {
                 min_batch_size :: non_neg_integer(),
                 max_batch_size :: non_neg_integer(),
                 parent :: pid(),
                 name :: atom(),
                 module :: module(),
                 hibernate_after = infinity :: non_neg_integer() | infinity,
                 reversed_batch = false :: boolean(),
                 flush_mailbox_on_terminate = false :: false | {true, non_neg_integer()},
                 batch_size_growth = exponential :: exponential | {aimd, pos_integer()},
                 append_batch = undefined :: undefined | fun((op(), term()) -> term() | {finish_batch, term()})}).

-record(state, {batch = [] :: batch(),
                batch_count = 0 :: non_neg_integer(),
                batch_size :: non_neg_integer(),
                config = #config{} :: #config{},
                state :: term(),
                needs_gc = false :: boolean(),
                debug :: list(),
                leftover_ops = [] :: [op()]}).

-export_type([from/0, reply_tag/0, op/0, batch/0,
              action/0, server_ref/0,
              request_id/0, request_id_collection/0]).

%%% Behaviour

-type action() ::
    {reply, from(), Msg :: term()} |
    garbage_collect.
%% an action that can be returned from handle_batch/2

-callback init(Args :: term()) ->
    {ok, State} |
    {ok, State, {continue, term()}} |
    ignore |
    {stop, Reason :: term()} |
    {error, Reason :: term()}
      when State :: term().

-callback handle_batch(batch(), State) ->
    {ok, State} |
    {ok, State, {continue, term()}} |
    {ok, [action()], State} |
    {ok, [action()], State, {continue, term()}} |
    {stop, Reason :: term()}
      when State :: term().

-callback handle_continue(Continue :: term(), State) ->
    {ok, State} |
    {ok, State, {continue, term()}} |
    {stop, Reason :: term()}
      when State :: term().

-callback terminate(Reason :: term(), State :: term()) -> term().

-callback format_status(State :: term()) -> term().

-callback append_batch(op(), OpaqueBatch :: term() | init_batch) ->
    OpaqueBatch :: term() | {finish_batch, OpaqueBatch :: term()}.

%% TODO: code_change

-optional_callbacks([handle_continue/2,
                     format_status/1,
                     terminate/2,
                     append_batch/2]).


%%%
%%% API
%%%

-spec start_link(Mod, Args) -> Result when
     Mod :: module(),
     Args :: term(),
     Result ::  {ok,pid()} | ignore | {error, Reason :: term()}.
start_link(Mod, Args) ->
    gen:start(?MODULE, link, Mod, {[], Args}, []).

-spec start_link(Name, Mod, Args) -> Result when
     Name :: {local, atom()} |
             {global, term()} |
             {via, atom(), term()} |
             undefined,
     Mod :: module(),
     Args :: term(),
     Result ::  {ok,pid()} | ignore | {error, Reason :: term()}.
start_link(Name, Mod, Args) ->
    gen_start(Name, Mod, Args, []).

-spec start_link(Name, Mod, Args, Options) -> Result when
     Name :: {local, atom()} |
             {global, term()} |
             {via, atom(), term()} |
             undefined,
     Mod :: module(),
     Args :: term(),
     Options :: list(),
     Result ::  {ok,pid()} | ignore | {error, Reason :: term()}.
start_link(Name, Mod, Args, Opts0) ->
    gen_start(Name, Mod, Args, Opts0).

%% pretty much copied wholesale from gen_server
init_it(Starter, self, Name, Mod, Args, Options) ->
    init_it(Starter, self(), Name, Mod, Args, Options);
init_it(Starter, Parent, Name0, Mod, {GBOpts, Args}, Options) ->
    Name = gen:name(Name0),
    Debug = gen:debug_options(Name, Options),
    HibernateAfter = gen:hibernate_after(Options),
    MaxBatchSize = proplists:get_value(max_batch_size, GBOpts,
                                       ?MAX_MAX_BATCH_SIZE),
    MinBatchSize = proplists:get_value(min_batch_size, GBOpts,
                                       ?MIN_MAX_BATCH_SIZE),
    ReverseBatch = proplists:get_value(reversed_batch, GBOpts, false),
    FlushMailbox = proplists:get_value(flush_mailbox_on_terminate, GBOpts, false),
    BatchSizeGrowth = proplists:get_value(batch_size_growth, GBOpts,
                                          exponential),
    %% call module_info/0 here to ensure that the module is loaded as else
    %% it may return false when calling erlang:function_exported/3 even
    %% if the callback is implemented.
    _ = Mod:module_info(),
    AppendBatch = case erlang:function_exported(Mod, append_batch, 2) of
                      true ->
                          fun Mod:append_batch/2;
                      false ->
                          undefined
                  end,
    BatchInit = init_batch(AppendBatch),
    Conf = #config{module = Mod,
                   parent = Parent,
                   name = Name,
                   min_batch_size = MinBatchSize,
                   max_batch_size = MaxBatchSize,
                   hibernate_after = HibernateAfter,
                   reversed_batch = ReverseBatch,
                   flush_mailbox_on_terminate = FlushMailbox,
                   batch_size_growth = BatchSizeGrowth,
                   append_batch = AppendBatch},
    case init_it(Mod, Args) of
        {ok, {ok, Inner0}} ->
            proc_lib:init_ack(Starter, {ok, self()}),
            State = #state{config = Conf,
                           batch = BatchInit,
                           batch_size = MinBatchSize,
                           state = Inner0,
                           debug = Debug},
            loop_wait(State, Parent);
        {ok, {ok, Inner0, {continue, Continue}}} ->
            proc_lib:init_ack(Starter, {ok, self()}),
            State0 = #state{config = Conf,
                            batch = BatchInit,
                            batch_size = MinBatchSize,
                            state = Inner0,
                            debug = Debug},
            State = handle_continue(Continue, State0),
            loop_wait(State, Parent);
        {ok, {stop, Reason}} ->
            %% For consistency, we must make sure that the
            %% registered name (if any) is unregistered before
            %% the parent process is notified about the failure.
            %% (Otherwise, the parent process could get
            %% an 'already_started' error if it immediately
            %% tried starting the process again.)
            gen:unregister_name(Name0),
            exit(Reason);
        {ok, {error, _Reason} = Error} ->
            %% The point of this clause is that we shall have a silent/graceful
            %% termination. The error reason will be returned to the
            %% 'Starter' ({error, Reason}), but *no* crash report.
            gen:unregister_name(Name0),
            proc_lib:init_fail(Starter, Error, {exit, normal});
        {ok, ignore} ->
            gen:unregister_name(Name0),
            proc_lib:init_fail(Starter, ignore, {exit, normal});
        {ok, Else} ->
            gen:unregister_name(Name0),
            exit({bad_return_value, Else});
        {'EXIT', Class, Reason, Stacktrace} ->
            gen:unregister_name(Name0),
            erlang:raise(Class, Reason, safe_stacktrace(Stacktrace))
    end.
init_it(Mod, Args) ->
    try
        {ok, Mod:init(Args)}
    catch
        throw:R -> {ok, R};
        Class:R:S -> {'EXIT', Class, R, S}
    end.

stop(Name) ->
    gen:stop(Name).

stop(Name, Reason, Timeout) ->
    gen:stop(Name, Reason, Timeout).

-spec cast(server_ref(), term()) -> ok.
cast({global,Name}, Request) ->
    catch global:send(Name, cast_msg(Request)),
    ok;
cast({via, Mod, Name}, Request) ->
    catch Mod:send(Name, cast_msg(Request)),
    ok;
cast({Name,Node}=Dest, Request) when is_atom(Name), is_atom(Node) ->
    do_cast(Dest, Request);
cast(Dest, Request) when is_atom(Dest) ->
    do_cast(Dest, Request);
cast(Dest, Request) when is_pid(Dest) ->
    do_cast(Dest, Request).


do_cast(Dest, Request) ->
  do_send(Dest, cast_msg(Request)),
  ok.

cast_msg(Request) ->
  {'$gen_cast', Request}.

-spec cast_batch(server_ref(), [term()]) -> ok.
cast_batch({global,Name}, Batch) ->
    catch global:send(Name, cast_batch_msg(Batch)),
    ok;
cast_batch({via, Mod, Name}, Batch) ->
    catch Mod:send(Name, cast_batch_msg(Batch)),
    ok;
cast_batch({Name,Node}=Dest, Batch) when is_atom(Name), is_atom(Node) ->
    do_cast_batch(Dest, Batch);
cast_batch(Dest, Batch) when is_atom(Dest) ->
    do_cast_batch(Dest, Batch);
cast_batch(Dest, Batch) when is_pid(Dest) ->
    do_cast_batch(Dest, Batch).

do_cast_batch(Dest, Batch) ->
    do_send(Dest, cast_batch_msg(Batch)),
    ok.

cast_batch_msg(Msgs0) when is_list(Msgs0) ->
    Msgs = lists:foldl(fun (Msg, Acc) ->
                               [{cast, Msg} | Acc]
                       end, [], Msgs0),
    {'$gen_cast_batch', Msgs, length(Msgs)};
cast_batch_msg(_) ->
    erlang:error(badarg).

-spec call(server_ref(), Request :: term()) -> term().
call(Name, Request) ->
    call(Name, Request, 5000).

-spec call(server_ref(), term(), non_neg_integer() | infinity) -> term().
call(Name, Request, Timeout) ->
    case catch gen:call(Name, '$gen_call', Request, Timeout) of
        {ok, Res} ->
            Res;
        {'EXIT', Reason} ->
            exit({Reason, {?MODULE, call, [Name, Request, Timeout]}})
    end.

-spec send_request(ServerRef, Request) -> ReqId when
      ServerRef :: server_ref(),
      Request :: term(),
      ReqId :: request_id().
send_request(ServerRef, Request) ->
    gen:send_request(ServerRef, '$gen_call', Request).

-spec send_request(ServerRef, Request, Label, ReqIdCollection) ->
    NewReqIdCollection when
      ServerRef :: server_ref(),
      Request :: term(),
      Label :: term(),
      ReqIdCollection :: request_id_collection(),
      NewReqIdCollection :: request_id_collection().
send_request(ServerRef, Request, Label, ReqIdCollection) ->
    gen:send_request(ServerRef, '$gen_call', Request, Label, ReqIdCollection).

-spec wait_response(ReqId, WaitTime) -> Result when
      ReqId :: request_id(),
      WaitTime :: response_timeout(),
      Response :: {reply, Reply :: term()}
                | {error, {Reason :: term(), server_ref()}},
      Result :: Response | 'timeout'.
wait_response(ReqId, WaitTime) ->
    gen:wait_response(ReqId, WaitTime).

-spec wait_response(ReqIdCollection, WaitTime, Delete) -> Result when
      ReqIdCollection :: request_id_collection(),
      WaitTime :: response_timeout(),
      Delete :: boolean(),
      Response :: {reply, Reply :: term()}
                | {error, {Reason :: term(), server_ref()}},
      Result :: {Response, Label :: term(),
                 NewReqIdCollection :: request_id_collection()}
              | 'no_request' | 'timeout'.
wait_response(ReqIdCollection, WaitTime, Delete) ->
    gen:wait_response(ReqIdCollection, WaitTime, Delete).

-spec receive_response(ReqId, Timeout) -> Result when
      ReqId :: request_id(),
      Timeout :: response_timeout(),
      Response :: {reply, Reply :: term()}
                | {error, {Reason :: term(), server_ref()}},
      Result :: Response | 'timeout'.
receive_response(ReqId, Timeout) ->
    gen:receive_response(ReqId, Timeout).

-spec receive_response(ReqIdCollection, Timeout, Delete) -> Result when
      ReqIdCollection :: request_id_collection(),
      Timeout :: response_timeout(),
      Delete :: boolean(),
      Response :: {reply, Reply :: term()}
                | {error, {Reason :: term(), server_ref()}},
      Result :: {Response, Label :: term(),
                 NewReqIdCollection :: request_id_collection()}
              | 'no_request' | 'timeout'.
receive_response(ReqIdCollection, Timeout, Delete) ->
    gen:receive_response(ReqIdCollection, Timeout, Delete).

-spec check_response(Msg, ReqId) -> Result when
      Msg :: term(),
      ReqId :: request_id(),
      Response :: {reply, Reply :: term()}
                | {error, {Reason :: term(), server_ref()}},
      Result :: Response | 'no_reply'.
check_response(Msg, ReqId) ->
    gen:check_response(Msg, ReqId).

-spec check_response(Msg, ReqIdCollection, Delete) -> Result when
      Msg :: term(),
      ReqIdCollection :: request_id_collection(),
      Delete :: boolean(),
      Response :: {reply, Reply :: term()}
                | {error, {Reason :: term(), server_ref()}},
      Result :: {Response, Label :: term(),
                 NewReqIdCollection :: request_id_collection()}
              | 'no_request' | 'no_reply'.
check_response(Msg, ReqIdCollection, Delete) ->
    gen:check_response(Msg, ReqIdCollection, Delete).

-spec reqids_new() -> NewReqIdCollection when
      NewReqIdCollection :: request_id_collection().
reqids_new() ->
    gen:reqids_new().

-spec reqids_add(ReqId, Label, ReqIdCollection) ->
    NewReqIdCollection when
      ReqId :: request_id(),
      Label :: term(),
      ReqIdCollection :: request_id_collection(),
      NewReqIdCollection :: request_id_collection().
reqids_add(ReqId, Label, ReqIdCollection) ->
    gen:reqids_add(ReqId, Label, ReqIdCollection).

-spec reqids_size(ReqIdCollection) -> non_neg_integer() when
      ReqIdCollection :: request_id_collection().
reqids_size(ReqIdCollection) ->
    gen:reqids_size(ReqIdCollection).

-spec reqids_to_list(ReqIdCollection) -> [{ReqId, Label}] when
      ReqIdCollection :: request_id_collection(),
      ReqId :: request_id(),
      Label :: term().
reqids_to_list(ReqIdCollection) ->
    gen:reqids_to_list(ReqIdCollection).

%% Internal

loop_wait(#state{config = #config{hibernate_after = Hib}} = State00, Parent) ->
    %% batches can accumulate a lot of garbage, collect it here
    %% evaluate gc state
    State0 = case State00 of
                 #state{needs_gc = true} ->
                     _ = garbage_collect(),
                     State00#state{needs_gc = false};
                 _ ->
                     State00
             end,
    receive
        Msg ->
            case Msg of
                {system, From, Request} ->
                    sys:handle_system_msg(Request, From, Parent,
                                          ?MODULE, State0#state.debug, State0);
                {'EXIT', Parent, Reason} ->
                    flush_mailbox(State0#state.config),
                    terminate(Reason, State0),
                    exit(Reason);
                _ ->
                    enter_loop_batched(Msg, Parent, State0)
            end
    after Hib ->
              proc_lib:hibernate(?MODULE, ?FUNCTION_NAME, [State0, Parent])
    end.

append_msg({'$gen_cast', Msg},
           #state{batch = Batch,
                  batch_count = BatchCount,
                  config = #config{append_batch = undefined}} = State0) ->
    State0#state{batch = [{cast, Msg} | Batch],
                 batch_count = BatchCount + 1};
append_msg({'$gen_cast', Msg},
           #state{batch = Batch,
                  batch_count = BatchCount,
                  config = #config{append_batch = Fun}} = State0) ->
    append_op(Fun, {cast, Msg}, Batch, BatchCount, State0);
append_msg({'$gen_cast_batch', Msgs, Count},
           #state{batch = Batch,
                  batch_count = BatchCount,
                  config = #config{append_batch = undefined}} = State0) ->
    State0#state{batch = Msgs ++ Batch,
                 batch_count = BatchCount + Count};
append_msg({'$gen_cast_batch', Msgs, _Count},
           #state{batch = Batch,
                  batch_count = BatchCount,
                  config = #config{append_batch = Fun}} = State0) ->
    case fold_append(lists:reverse(Msgs), Fun, Batch, BatchCount, State0) of
        {finish, Rest, State} ->
            {finish, State#state{leftover_ops = Rest}};
        #state{} = State ->
            State
    end;
append_msg({'$gen_call', From, Msg},
           #state{batch = Batch,
                  batch_count = BatchCount,
                  config = #config{append_batch = undefined}} = State0) ->
    State0#state{batch = [{call, From, Msg} | Batch],
                 batch_count = BatchCount + 1};
append_msg({'$gen_call', From, Msg},
           #state{batch = Batch,
                  batch_count = BatchCount,
                  config = #config{append_batch = Fun}} = State0) ->
    append_op(Fun, {call, From, Msg}, Batch, BatchCount, State0);
append_msg(Msg, #state{batch = Batch,
                       batch_count = BatchCount,
                       config = #config{append_batch = undefined}} = State0) ->
    State0#state{batch = [{info, Msg} | Batch],
                 batch_count = BatchCount + 1};
append_msg(Msg, #state{batch = Batch,
                       batch_count = BatchCount,
                       config = #config{append_batch = Fun}} = State0) ->
    append_op(Fun, {info, Msg}, Batch, BatchCount, State0).

append_op(Fun, Op, {batch, Batch}, BatchCount, State0) ->
    case Fun(Op, Batch) of
        {finish_batch, NewBatch} ->
            {finish, State0#state{batch = {batch, NewBatch},
                                  batch_count = BatchCount + 1}};
        NewBatch ->
            State0#state{batch = {batch, NewBatch},
                         batch_count = BatchCount + 1}
    end.

fold_append([], _Fun, Batch, Count, State0) ->
    State0#state{batch = Batch, batch_count = Count};
fold_append([Op | Rest], Fun, {batch, Batch}, Count, State0) ->
    case Fun(Op, Batch) of
        {finish_batch, NewBatch} ->
            {finish, Rest, State0#state{batch = {batch, NewBatch},
                                        batch_count = Count + 1}};
        NewBatch ->
            fold_append(Rest, Fun, {batch, NewBatch}, Count + 1, State0)
    end.

enter_loop_batched(Msg, Parent, #state{debug = []} = State0) ->
    case append_msg(Msg, State0) of
        {finish, State} ->
            loop_batched_finish(State, Parent);
        #state{} = State ->
            loop_batched(State, Parent)
    end;
enter_loop_batched(Msg, Parent, State0) ->
    State1 = handle_debug_in(State0, Msg),
    case append_msg(Msg, State1) of
        {finish, State} ->
            loop_batched_finish(State, Parent);
        #state{} = State ->
            loop_batched(State, Parent)
    end.

next_batch_size(BatchSize, #config{max_batch_size = Max,
                                   batch_size_growth = Growth}) ->
    case Growth of
        exponential ->
            min(Max, BatchSize * 2);
        {aimd, Step} ->
            min(Max, BatchSize + Step)
    end.

loop_batched_finish(#state{config = Config,
                           batch_size = BatchSize,
                           leftover_ops = LeftoverOps} = State0,
                    Parent) ->
    State = complete_batch(State0),
    NewBatchSize = next_batch_size(BatchSize, Config),
    State1 = State#state{batch_size = NewBatchSize, leftover_ops = []},
    process_leftover_ops(LeftoverOps, Parent, State1).

process_leftover_ops([], Parent, State) ->
    loop_batched(State, Parent);
process_leftover_ops(LeftoverOps, Parent, State0) ->
    %% LeftoverOps are already in the correct `{cast, Msg}` format.
    %% We just need to wrap them in a `$gen_cast_batch` message.
    %% Note: They are in chronological order, but `$gen_cast_batch` expects
    %% them to be reversed (as cast_batch_msg/1 does).
    ReversedOps = lists:reverse(LeftoverOps),
    Msg = {'$gen_cast_batch', ReversedOps, length(ReversedOps)},
    case append_msg(Msg, State0) of
        {finish, State} ->
            State1 = complete_batch(State),
            NewBatchSize = next_batch_size(State1#state.batch_size, State1#state.config),
            State2 = State1#state{batch_size = NewBatchSize},
            NewLeftoverOps = State2#state.leftover_ops,
            process_leftover_ops(NewLeftoverOps, Parent, State2#state{leftover_ops = []});
        #state{} = State ->
            loop_batched(State, Parent)
    end.

loop_batched(#state{config = Config,
                    batch_size = BatchSize,
                    batch_count = BatchCount} = State0,
             Parent) when BatchCount >= BatchSize ->
    % complete batch after seeing batch_size writes
    State = complete_batch(State0),
    NewBatchSize = next_batch_size(BatchSize, Config),
    loop_wait(State#state{batch_size = NewBatchSize}, Parent);
loop_batched(State0, Parent) ->
    receive
        Msg ->
            case Msg of
                {system, From, Request} ->
                    sys:handle_system_msg(Request, From, Parent,
                                          ?MODULE, State0#state.debug, State0);
                {'EXIT', Parent, Reason} ->
                    flush_mailbox(State0#state.config),
                    terminate(Reason, State0),
                    exit(Reason);
                _ ->
                    enter_loop_batched(Msg, Parent, State0)
            end
    after 0 ->
              State = complete_batch(State0),
              Config = State#state.config,
              NewBatchSize = max(Config#config.min_batch_size,
                                 State#state.batch_size div 2),
              loop_wait(State#state{batch_size = NewBatchSize}, Parent)
    end.

terminate(Reason, #state{config = #config{module = Mod}, state = Inner}) ->
    catch Mod:terminate(Reason, Inner),
    ok.

init_batch(undefined) ->
    [];
init_batch(_) ->
    {batch, init_batch}.

complete_batch(#state{batch_count = 0} = State) ->
    State;
complete_batch(#state{batch = Batch0,
                      config = #config{module = Mod,
                                       reversed_batch = ReverseBatch,
                                       append_batch = AppendBatch},
                      state = Inner0,
                      debug = Debug0} = State0) ->
    Batch = case {AppendBatch, ReverseBatch} of
                {undefined, false} ->
                    lists:reverse(Batch0);
                {undefined, true} ->
                    Batch0;
                _ ->
                    {batch, Opaque} = Batch0,
                    Opaque
            end,

    BatchReset = init_batch(AppendBatch),

    try Mod:handle_batch(Batch, Inner0) of
        Result ->
            handle_batch_result(Result, State0, Debug0, BatchReset)
    catch
        throw:Result ->
            handle_batch_result(Result, State0, Debug0, BatchReset);
        Class:Reason:Stacktrace ->
            flush_mailbox(State0#state.config),
            terminate(Reason, State0),
            erlang:raise(Class, Reason, safe_stacktrace(Stacktrace))
    end.

handle_batch_result({ok, Inner}, State0, _Debug0, BatchReset) ->
    State0#state{batch = BatchReset,
                 state = Inner,
                 batch_count = 0};
handle_batch_result({ok, Inner, {continue, Continue}}, State0, _Debug0, BatchReset) ->
    handle_continue(Continue,
                    State0#state{batch = BatchReset,
                                 state = Inner,
                                 batch_count = 0});
handle_batch_result({ok, Actions, Inner}, State0, Debug0, BatchReset) when is_list(Actions) ->
    {ShouldGc, Debug} = handle_actions(Actions, Debug0),
    State0#state{batch = BatchReset,
                 batch_count = 0,
                 state = Inner,
                 needs_gc = ShouldGc,
                 debug = Debug};
handle_batch_result({ok, Actions, Inner, {continue, Continue}}, State0, Debug0, BatchReset) when is_list(Actions) ->
    {ShouldGc, Debug} = handle_actions(Actions, Debug0),
    handle_continue(Continue,
                    State0#state{batch = BatchReset,
                                 batch_count = 0,
                                 state = Inner,
                                 needs_gc = ShouldGc,
                                 debug = Debug});
handle_batch_result({stop, Reason}, State0, _Debug0, _BatchReset) ->
    flush_mailbox(State0#state.config),
    terminate(Reason, State0),
    exit(Reason).

handle_actions(Actions, Debug0) ->
    lists:foldl(fun ({reply, From, Msg},
                     {ShouldGc, Dbg}) ->
                        gen:reply(From, Msg),
                        {Pid, _Tag} = From,
                        {ShouldGc,
                         handle_debug_out(Pid, Msg, Dbg)};
                    (garbage_collect, {_, Dbg}) ->
                        {true, Dbg}
                end, {false, Debug0}, Actions).


handle_continue(Continue, #state{config = #config{module = Mod},
                                 state = Inner0} = State0) ->
    try Mod:handle_continue(Continue, Inner0) of
        Result ->
            handle_continue_result(Result, State0)
    catch
        throw:Result ->
            handle_continue_result(Result, State0);
        Class:Reason:Stacktrace ->
            flush_mailbox(State0#state.config),
            terminate(Reason, State0),
            erlang:raise(Class, Reason, safe_stacktrace(Stacktrace))
    end.

handle_continue_result({ok, Inner}, State0) ->
    State0#state{state = Inner};
handle_continue_result({ok, Inner, {continue, NextContinue}}, State0) ->
    handle_continue(NextContinue, State0#state{state = Inner});
handle_continue_result({stop, Reason}, State0) ->
    flush_mailbox(State0#state.config),
    terminate(Reason, State0),
    exit(Reason).

handle_debug_in(#state{debug = Dbg0} = State, Msg) ->
    Dbg = sys:handle_debug(Dbg0, fun write_debug/3, ?MODULE, {in, Msg}),
    State#state{debug = Dbg}.

handle_debug_out(_, _, []) ->
    [];
handle_debug_out(Pid, Msg, Dbg) ->
    Evt = {out, {self(), Msg}, Pid},
    sys:handle_debug(Dbg, fun write_debug/3, ?MODULE, Evt).

%% Here are the sys call back functions

system_continue(Parent, Debug, State) ->
    % TODO check if we've written to the current batch or not
    loop_batched(State#state{debug = Debug}, Parent).

-spec system_terminate(term(), pid(), list(), term()) -> no_return().
system_terminate(Reason, _Parent, _Debug, State) ->
    flush_mailbox(State#state.config),
    terminate(Reason, State),
    exit(Reason).

system_get_state(State) ->
    {ok, State}.

format_status(_Reason, [_PDict, SysState, Parent, Debug,
                        #state{config = #config{name = Name,
                                                module = Mod},
                               state = State }]) ->
    Header = gen:format_status_header("Status for batching server", Name),
    Log = sys_get_log(Debug),

    [{header, Header},
     {data,
      [
       {"Status", SysState},
       {"Parent", Parent},
       {"Logged Events", Log}]} |
     try Mod:format_status(State) of
         L when is_list(L) -> L;
         T -> [T]
     catch
         error:undef:_ -> [State];
         _:_ -> [State]
     end].

sys_get_log(Debug) ->
    sys:get_log(Debug).

write_debug(Dev, Event, Name) ->
    io:format(Dev, "~p event = ~p~n", [Name, Event]).

do_send(Dest, Msg) ->
    try erlang:send(Dest, Msg)
    catch
        error:_ -> ok
    end,
    ok.

gen_start(undefined, Mod, Args, Opts0) ->
    %% filter out gen batch server specific options as the options type in gen
    %% is closed and dialyzer would complain.
    {GBOpts, Opts} = lists:partition(fun ({Key, _}) ->
                                             Key == max_batch_size orelse
                                             Key == min_batch_size orelse
                                             Key == reversed_batch orelse
                                             Key == flush_mailbox_on_terminate orelse
                                             Key == batch_size_growth;
                                         (_) -> false
                                     end, Opts0),
    gen:start(?MODULE, link, Mod, {GBOpts, Args}, Opts);
gen_start(Name, Mod, Args, Opts0) ->
    %% filter out gen batch server specific options as the options type in gen
    %% is closed and dialyzer would complain.
    {GBOpts, Opts} = lists:partition(fun ({Key, _}) ->
                                             Key == max_batch_size orelse
                                             Key == min_batch_size orelse
                                             Key == reversed_batch orelse
                                             Key == flush_mailbox_on_terminate orelse
                                             Key == batch_size_growth;
                                         (_) -> false
                                     end, Opts0),
    gen:start(?MODULE, link, Name, Mod, {GBOpts, Args}, Opts).


%% Strip function arguments from stacktrace frames to avoid formatting
%% potentially huge terms.
safe_stacktrace(Stacktrace) ->
    lists:map(fun({M, F, Args, Info}) when is_list(Args) ->
                      {M, F, length(Args), Info};
                 (Frame) ->
                      Frame
              end, Stacktrace).

%% When disabled (default) do nothing. When enabled, collect a sample of up to
%% N messages and the total mailbox count, write them to the process dictionary
%% under the key 'mailbox_summary', then drain the remaining messages.
%% This prevents proc_lib crash reports from pretty-printing potentially large
%% messages (e.g. WAL write commands containing binary payloads), which can
%% cause unbounded memory growth. The summary is written before terminate/2 is
%% called so that the callback can inspect or forward it.
flush_mailbox(#config{flush_mailbox_on_terminate = false}) ->
    ok;
flush_mailbox(#config{flush_mailbox_on_terminate = {true, N}}) ->
    {Total, Sample} = drain_mailbox_sample(N, 0, []),
    erlang:put(mailbox_summary, #{total => Total, messages => Sample}),
    ok.

drain_mailbox_sample(0, Count, Acc) ->
    {Count + drain_mailbox_count(0), lists:reverse(Acc)};
drain_mailbox_sample(N, Count, Acc) ->
    receive
        Msg ->
            drain_mailbox_sample(N - 1, Count + 1, [Msg | Acc])
    after 0 ->
        {Count, lists:reverse(Acc)}
    end.

drain_mailbox_count(Count) ->
    receive
        _ ->
            drain_mailbox_count(Count + 1)
    after 0 ->
        Count
    end.
