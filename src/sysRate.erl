%%% ----------------------------------------------------------
%%% #0.    BASIC INFORMATION
%%% ----------------------------------------------------------
%%% %CCaseFile:	regBucket.erl %
%%% Author:	etxpell
%%% Description: A leaky bucket used for regulating spontaneous delets
%%%	and PBX commands towargds core network
%%%
%%% Modules used:    
%%%
%%% ----------------------------------------------------------

-module(sysRate).
-id('39/190 55-CNA 113 206 Ux').
-vsn('/main/R6A_1/R9B/R10A/R12A/R14A/R15A/R18A/R19A/3').

%%% ----------------------------------------------------------
%%% %CCaseTemplateFile:	module.erl %
%%% %CCaseTemplateId: 53/002 01-LXA 119 334 Ux, Rev: /main/5 %
%%%
%%% %CCaseCopyrightBegin%
%%% Copyright (c) Ericsson AB 2008-2012 All rights reserved.
%%% 
%%% The information in this document is the property of Ericsson.
%%% 
%%% Except as specifically authorized in writing by Ericsson, the 
%%% receiver of this document shall keep the information contained 
%%% herein confidential and shall protect the same in whole or in 
%%% part from disclosure and dissemination to third parties.
%%% 
%%% Disclosure and disseminations to the receivers employees shall 
%%% only be made on a strict need to know basis.
%%% %CCaseCopyrightEnd%
%%%
%%% ----------------------------------------------------------
%%% #1.    REVISION LOG
%%% ----------------------------------------------------------
%%% Rev    Date        Name     What
%%% -----  ----------  -------  ------------------------
%%%
%%% ----------------------------------------------------------
 
%%------------------
%% The supervision server
-export([start_link/0]).
-export([stop/0]).

%%------------------
%% The bucket interface
-export([create/2]).
-export([is_limiter_running/1]).
-export([is_request_allowed/1]).
-export([is_request_allowed/2]).
-export([read_counters/1]).
-export([read_counter_good/1]).
-export([read_counter_rejected/1]).

-export([set_rate/2]).
-export([set_period/2]).
-export([set_burst_limit/2]).
-export([reset_burst_limit/1]).

-export([on/1]).
-export([off/1]). 
%% -export([clear/1]).
-export([list_limiter/1]).
-export([list_all_limiters/0]).
%% -export([print_all_limiters/0]).
%% -export([is_below_limit/1]).


%%------------------
%% For testing
-export([tick/1]).
-export([limiter_pid/1]).

%%------------------
%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2, code_change/3]).


-behaviour(gen_server).

-record(s, {things}).
-record(sysRate, {name, pid, config=[]}).
-record(lim, {name, state=on, type=meter,
              rate=100, period=100, 
              level=0, limit=100, 
              auto_burst_limit=true,
              queue_type=lifo,
              manual_tick=false, 
              leak_ts=0, timer,
              good=0, rejected=0,
              spare1, spare2}).

%%------------------
%% The supervision server
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

stop() ->
    server_call(stop).

server_call(Req) ->
    gen_server:call(?MODULE, Req).


init([]) ->
    process_flag(trap_exit, true),
    new_pid_table(),
    {ok, #s{}}.

handle_call({create, Name, Config}, _From, S) ->
    {reply, start_limiter(Name, Config), S};
handle_call(list_all_limiters, _From, S) ->
    {reply, do_list_all_limiters(), S};
handle_call(stop, _From, S) ->
    {stop, normal, ok, S};
handle_call(_Request, _From, S) ->
    Reply = ok,
    {reply, Reply, S}.

handle_cast(_Msg, S) ->
    {noreply, S}.

handle_info({'EXIT', Pid, _}, S) ->
    case lookup_limiter_by_pid(Pid) of
        #sysRate{name=Name, config=Config} ->
            del_hanging_pid_item(Pid),
            start_limiter(Name, Config);
        _ ->
            ok
    end,
    {noreply, S};
handle_info(_Info, S) ->
    {noreply, S}.

terminate(_Reason, _S) ->
    del_all_pids(),
    ok.

code_change(_OldVsn, S, _Extra) ->
    {ok, S}.



%%------------------
%% The bucket
create_help() ->
    ["creates a rate limit bucket.",
     "Name is term(), Config is bucket configuration property list",
     "Example sysRate:create({netid, 4}, [{rate, 20}]).",
     "which creates a bucket that will allow 20 requests per second",
     "",
     "The bucket comes in two flavours, a simple rate enforcer, and a "
     "more complex prioritized queue flow limiter",
     "",
     "The simple bucket does not buffer requests, but is simply a counter. "
     "It is what is called a meter on the wikipedia page for leaky "
     "buckets.",
     "",
     "The complex bucket accepts priority and timeout for requests. The "
     "intention is to supply the same priorities and times as for PLC, but "
     "any set of priorities may really be used. Note that, just as PLC, "
     "priorities goes backwards, i.e., priority=0 is the best and "
     "priority=100 the worst (i.e., served only if no other in the queue)"].

create(Name, Config) ->
    case is_config_ok(Config) of
        ok -> server_call({create, Name, Config});
        Err -> Err
    end.

list_all_limiters() ->
    server_call(list_all_limiters).

is_request_allowed(Name) ->
    is_request_allowed(Name, 0).
is_request_allowed(Name, Prio) ->
    limiter_call(Name, {is_request_allowed, Prio}).

read_counters(Name) ->
    read_counter(Name, all).
read_counter_good(Name) ->
    read_counter(Name, good).
read_counter_rejected(Name) ->
    read_counter(Name, rejected).

read_counter(Name, Spec) ->
    limiter_call(Name, {read_counter, Spec}).

set_rate(Name, Rate) ->
    new_config_call(Name, {rate, Rate}).

set_period(Name, Period) ->
    new_config_call(Name, {period, Period}).

set_burst_limit(Name, Limit) ->
    new_config_call(Name, {burst_size, Limit}).

reset_burst_limit(Name) ->
    new_config_call(Name, auto_burst_size).

on(Name) -> 
    new_config_call(Name, {state, on}).

off(Name) -> 
    new_config_call(Name, {state, off}).

new_config_call(Name, Config) when not is_list(Config) ->
    new_config_call(Name, [Config]);
new_config_call(Name, Config) when is_list(Config) ->
    case is_config_ok(Config) of
        ok  -> limiter_call(Name, {new_config, Config});
        Err -> Err
    end.

list_limiter(Name) ->
    limiter_call(Name, list).



tick(Name) ->
    limiter_call(Name, tick).


limiter_call(Name, Req) ->
    limiter_call2(limiter_pid(Name), Req).

limiter_call2(Pid, Req) when is_pid(Pid) ->
    MonRef = erlang:monitor(process, Pid),
    Pid ! {call, {self(), MonRef}, Req},
    receive
        {answer, MonRef, Ans} ->
            erlang:demonitor(MonRef),
            Ans;
        {'DOWN', MonRef, process, _, _} ->
            {error, noproc}
    end;
limiter_call2(_, _) ->
    {error, noproc}.

start_limiter(Name, Config) ->
    spawn_link(fun() -> init_limiter(Name, Config) end).

stop_limiter(Pid) ->
    limiter_call(Pid, stop).

init_limiter(Name, Config) ->
    register_limiter_name(Name),
    ins_pid(Name, self(), Config),
    loop_limiter(init_limiter_state(Name, Config)).

register_limiter_name(Name) ->
    %% change the register into sysProc
    register(Name, self()).

limiter_pid(Pid) when is_pid(Pid) ->
    Pid;
limiter_pid(Name) ->
    whereis(Name).

loop_limiter(stop) ->
    ok;
loop_limiter(Lim) ->
    receive
        tick ->
            NewLim = timer_tick(Lim),
            loop_limiter(NewLim);
        {call, From, Req} ->
            {Res, NewLim} = handle_limiter_call(Req, Lim),
            send_call_answer(From, Res),
            loop_limiter(NewLim)
    end.
    
handle_limiter_call({read_counter, Spec}, Lim) ->
    {get_counter(Spec, Lim), Lim};
handle_limiter_call({is_request_allowed, Prio}, Lim) ->
    case is_bucket_below_limit(Prio, Lim) of
        true ->
            {true, inc_bucket_level(inc_good(Lim))};
        _ ->
            {false, inc_rejected(Lim)}
    end;
handle_limiter_call(tick, Lim) ->
    {ok, timer_tick(Lim)};
handle_limiter_call(list, Lim) ->
    {pretty_lim(Lim), Lim};
handle_limiter_call({new_config, Config}, Lim) ->
    update_pid_table(Lim, Config),
    {ok, reconfig_action(update_limiter_config(Lim, Config))};
handle_limiter_call(stop, _) ->
    {ok, stop}.

send_call_answer({Pid, Ref}, Ans) ->
    Pid ! {answer, Ref, Ans}.

init_limiter_state(Name, Config) ->
    seq(#lim{name=Name},
        [fun(L2) -> update_limiter_config(L2, Config) end,
         fun update_leak_ts/1,
         fun reconfig_action/1]).

pretty_lim(Lim) ->
    Vals = tl(tuple_to_list(Lim)),
    lists:zip(record_info(fields, lim), Vals).
    
%%------------------
%% Configuration stuff

configuration_help() ->
    ["Bucket configuration items:",
     "  {rate, Rate::int()}  - sets the rate, i.e., requests per second",
     "  {period, Time::int()}  - sets the leak period in ms. This tells how "
     "often the bucket should leak. The period should be less than 1000ms.",
     "  {burst_size, Level::int()}  - sets the burst size, or Level at which "
     "the bucket is considered full. Defaults to Rate but can be manually "
     "controlled. A low burst_limit gives bad burst handling properties, "
     "i.e., requests gets rejected even though the average rate is less "
     "than configured. A seriously too high burst limit (like 10*Rate) "
     "would have the effect that the 10*Rate first requests are not limited "
     "at all while the rest are limited to rate."
     "  {type, meter | priority} -  set the bucket type to either the simple "
     "non-buffering meter type, or the buffering prioritized queue type. "
     "Default type is meter",
     "  {queue_type, lifo | fifo} - only applicable to the prioritized type. "
     "The queue may be a LIFO or a FIFO. The upside of a LIFO is that during "
     "rate limiting, the allowed request is the one with the lowest latency. "
     "The downside is that requests are reordered within a given priority. "
     "The upside and downside of a FIFO is the exact opposite, i.e., "
     "the allowed request is the one with the highest latency, and the "
     "requests within a given priority is not reordered. Note that requests "
     "with different priority is likely to be  reordered during rate limiting. "
     "Default is LIFO."].
     
reconfig_action(Lim) ->     
    restart_timer(Lim).

is_config_ok(Config) ->
    case update_limiter_config(#lim{}, Config) of
        #lim{} -> ok;
        Err -> Err
    end.

update_limiter_config(Lim, NewConfig) ->
    update_limiter_config_items(Lim, NewConfig).

update_limiter_config_items(Lim, Config) ->
    %% We update the accumulator as long as it stays a lim record,
    %% otherwise it's an error and we just pass that through.
    UpdateFun = fun(C, A) when is_record(Lim, lim) -> 
                        update_one_config_item(C, A);
                   (_C, A) -> 
                        A 
                end,
    lists:foldl(UpdateFun, Lim, Config).

update_one_config_item({rate, Rate}, Lim) 
  when is_integer(Rate) , (Rate > 0) ->    
    maybe_update_burst_limit(Lim#lim{rate=Rate});
update_one_config_item({burst_size, Level}, Lim) ->    
    Lim#lim{limit=Level, auto_burst_limit=false};
update_one_config_item(auto_burst_size, Lim) -> 
    maybe_update_burst_limit(Lim#lim{auto_burst_limit=true});
update_one_config_item({period, Time}, Lim) 
  when is_integer(Time) , (Time > 0) , (Time < 1000) -> 
    Lim#lim{period=Time};
update_one_config_item({state, State}, Lim) 
  when (State==on) ; (State == off) -> 
    clear_limiter(Lim#lim{state=State});
update_one_config_item({type, Type}, Lim) 
  when (Type==meter) ; (Type == prio) -> 
    clear_limiter(Lim#lim{type=Type});
update_one_config_item(manual_tick, Lim) -> 
    update_one_config_item({manual_tick, true}, Lim);
update_one_config_item({manual_tick, Bool}, Lim) when is_boolean(Bool) -> 
    Lim#lim{manual_tick=Bool};
update_one_config_item(What, _Lim) -> 
    {error, {badarg, What}}.

maybe_update_burst_limit(Lim=#lim{rate=Rate, auto_burst_limit=true}) ->
    Lim#lim{limit=Rate};
maybe_update_burst_limit(Lim) ->
    Lim.

clear_limiter(Lim) ->
    cancel_timer(Lim#lim{level=0}).

restart_timer(Lim) ->
    start_timer(cancel_timer(Lim)).

start_timer(Lim=#lim{manual_tick=true}) ->
    Lim;
start_timer(Lim=#lim{period=Time}) ->
    Lim#lim{timer=start_timer(Time, tick)}.

start_timer(Time, Msg) ->
    erlang:send_after(Time, self(), Msg).

cancel_timer(Lim=#lim{timer=Timer}) ->
    Lim#lim{timer=cancel_timer(Timer)};
cancel_timer(Timer) when is_reference(Timer) ->
    erlang:cancel_timer(Timer),
    undefined;
cancel_timer(_) ->
    undefined.

is_limiter_running(Name) ->
    is_pid(limiter_pid(Name)).

update_pid_table(#lim{name=Name}, NewConfig) ->
    R = pid_tab_lookup_or_create(Name),
    ins_pid(merge_config(R, NewConfig)).

merge_config(R=#sysRate{config=OldConfig}, NewConfig) ->
    R#sysRate{config=merge_config(OldConfig, NewConfig)};
merge_config(Old, New) ->
    MergeFun = fun(C, A) -> merge_one_config_item(C, A) end,
    lists:foldl(MergeFun, Old, New).

merge_one_config_item(X, A) when is_atom(X) ->
    case lists:member(X, A) of
        true -> A;
        _ -> [X|A]
    end;
merge_one_config_item(New={T,_}, A) ->
    lists:keystore(T, 1, A, New).

ins_pid(Name, Pid, Config) ->
    ins_pid(#sysRate{name=Name, pid=Pid, config=Config}).

ins_pid(R=#sysRate{name=Name, pid=Pid}) ->
    ets:insert(pid_table_name(), [R, #sysRate{name=Pid, pid=Name}]).

lookup_limiter_by_pid(Pid) when is_pid(Pid) ->
    case pid_tab_lookup(Pid) of
        #sysRate{pid=Name} -> pid_tab_lookup(Name);
        _ -> undefined
    end.

pid_tab_lookup(Key) ->
    case ets:lookup(pid_table_name(), Key) of
        [R] -> R;
        _ -> undefined
    end.

pid_tab_lookup_or_create(Name) ->
    case pid_tab_lookup(Name) of
        R=#sysRate{} -> R;
        _ -> #sysRate{name=Name, pid=self()}
    end.

del_hanging_pid_item(Pid) ->
    ets:delete(pid_table_name(), Pid).

new_pid_table() ->
    ets:new(pid_table_name(), [set, public, named_table, 
                               {keypos, #sysRate.name}]).    

del_all_pids() ->
    [stop_limiter(Pid) || Pid <- all_limiter_pids()].

all_limiter_pids() ->
    [R#sysRate.pid  || R <- all_limiters()].

all_limiters() ->
    [R  || R <- all_table(), is_pid(R#sysRate.pid)].

all_table() ->
    ets:tab2list(pid_table_name()).


pid_table_name() ->
    sysRate_pids.


%%------------------
%% Lowlevel bucket stuff

is_bucket_below_limit(Prio, #lim{state=on, level=Level, limit=Limit}) 
  when Level >= Limit ->
%%  when Level >= round(Limit+(Limit*Prio/2)) ->
    false;
is_bucket_below_limit(_, _) ->
    true.

inc_bucket_level(Lim=#lim{level=Level}) ->
    Lim#lim{level=Level+1}.

timer_tick(Lim) ->
    start_timer(leak(Lim)).

leak(Lim) ->
    NewLim = update_leak_ts(Lim),
    update_level_with_leak(NewLim, calc_leak(NewLim, Lim)).

update_level_with_leak(Lim=#lim{level=Level}, Leak) ->
    NewLevel = max((Level-Leak), 0),
    Lim#lim{level=NewLevel}.

calc_leak(#lim{leak_ts=NewTS, rate=Rate}, #lim{leak_ts=OldTS}) ->
    %% If OldTS > NewTS then we have just passed the second mark. In
    %% that case we should make sure that the total rate for the last
    %% second is correct by adjusting so that the whole rate has been
    %% used.
    LeakAdjustFromPrevSecond = 
        if OldTS > NewTS -> 
                LeakedPrevsecond=time_to_leak(OldTS, Rate),
                Rate - LeakedPrevsecond;
           true ->
                0
        end,
    
    %% Start calculating leak from 0 when we have passed the second
    %% mark.
    LeakedSoFar = if OldTS > NewTS -> 0;
		     true -> time_to_leak(OldTS, Rate)
		  end,
    
    LeakUpTillNewTS = time_to_leak(NewTS, Rate),
    
    Leak = LeakUpTillNewTS - LeakedSoFar + LeakAdjustFromPrevSecond,
    Leak.

time_to_leak(Time, Rate) ->
    round(Time*Rate/1000).

update_leak_ts(Lim) ->
    Lim#lim{leak_ts=timestamp_for_tick(Lim)}.

timestamp_for_tick(Lim=#lim{manual_tick=true}) ->
    timestamp_for_manual_tick(Lim);
timestamp_for_tick(_) ->
    ts_ms().

timestamp_for_manual_tick(#lim{leak_ts=OldTS, period=Period}) ->
    timestamp_add_wrap_on_second(OldTS, Period).

timestamp_add_wrap_on_second(TS, AddMs) ->
    case TS+AddMs of
        X when X >= 1000 -> X -1000;
        X -> X
    end.

do_list_all_limiters() ->
    sort([list_limiter(P) || P <- all_limiter_pids()]).
    
%% -----------------------------
%% the counters
get_counter(good, #lim{good=Good}) ->
    Good;
get_counter(rejected, #lim{rejected=Rej}) ->
    Rej;
get_counter(all, #lim{good=Good, rejected=Rej}) ->
    {Good, Rej}.

inc_good(Lim=#lim{good=Good}) ->
    Lim#lim{good=Good+1}.

inc_rejected(Lim=#lim{rejected=Rej}) ->
    Lim#lim{rejected=Rej+1}.

%% -----------------------------
%% timestamp primitives
ts_ms() ->
    round(element(3, ts()) / 1000).
ts() ->
    os:timestamp().


%%-------------------
%% Run a number of functions sequentially.
%% seq([H|R]) -> seq(H(), R).

seq(Res={error, _}, _) ->
    Res;
seq(Data, [H|R]) ->
    seq(H(Data), R);
seq(Data, []) ->
    Data.


%% -----------------------------
%% simple utilities / shortcuts

sort(L) -> lists:sort(L).


