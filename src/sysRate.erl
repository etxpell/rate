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
-export([define/2]).
-export([is_limiter_running/1]).
-export([is_request_allowed/1]).
-export([read_counters/1]).
-export([read_counter_good/1]).
-export([read_counter_rejected/1]).

-export([set_rate/2]).
-export([set_period/2]).
-export([set_burst_limit/2]).
-export([reset_burst_limit/2]).

-export([on/1]).
-export([off/1]). 
%% -export([clear/1]).
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
-record(lim, {state=on, rate=100, period=100, level=0, limit=100, 
              leak_ts=0,
              manual_tick=false, timer,
              auto_burst_limit=true,
              good=0, rejected=0}).

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

handle_call({define, Name, Config}, _From, S) ->
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
define_help() ->
    ["defines a rate limit bucket.",
     "Name is term(), Config is bucket configuration property list",
     "Example sysRate:define({netid, 4}, [{rate, 20}]).",
     "which defines a bucket that will allow 20 requests per second",
     "",
     "The bucket does not buffer requests, but is simply a counter. It
     is what is called a meter on the wikipedia page for leaky
     buckets"].

define(Name, Config) ->
    server_call({define, Name, Config}).

list_all_limiters() ->
    server_call(list_all_limiters).

is_request_allowed(Name) ->
    limiter_call(Name, is_request_allowed).

read_counters(Name) ->
    read_counter(Name, all).
read_counter_good(Name) ->
    read_counter(Name, good).
read_counter_rejected(Name) ->
    read_counter(Name, rejected).

read_counter(Name, Spec) ->
    limiter_call(Name, {read_counter, Spec}).

set_rate(Name, Rate) when is_integer(Rate)->
    new_config_call(Name, {rate, Rate}).

set_period(Name, Period) when is_integer(Period), Period < 1000 ->
    new_config_call(Name, {period, Period}).

set_burst_limit(Name, Limit) when is_integer(Limit) ->
    new_config_call(Name, {burst_size, Limit}).

reset_burst_limit(Name, Limit) when is_integer(Limit) ->
    new_config_call(Name, auto_burst_size).

on(Name) -> 
    new_config_call(Name, {state, on}).

off(Name) -> 
    new_config_call(Name, {state, off}).

new_config_call(Name, Config) when not is_list(Config) ->
    new_config_call(Name, [Config]);
new_config_call(Name, Config) when is_list(Config) ->
    limiter_call(Name, {new_config, Config}).
    



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
    loop_limiter(init_limiter_state(Config)).

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
        {call, From, Req} ->
            {Res, NewLim} = handle_limiter_call(Req, Lim),
            send_call_answer(From, Res),
            loop_limiter(NewLim)
    end.
    
handle_limiter_call({read_counter, Spec}, Lim) ->
    {get_counter(Spec, Lim), Lim};
handle_limiter_call(is_request_allowed, Lim) ->
    case is_bucket_below_limit(Lim) of
        true ->
            {true, inc_bucket_level(inc_good(Lim))};
        _ ->
            {false, inc_rejected(Lim)}
    end;
handle_limiter_call(tick, Lim) ->
    {ok, timer_tick(Lim)};
handle_limiter_call({new_config, Config}, Lim) ->
    {ok, reconfig_action(update_limiter_config(Lim, Config))};
handle_limiter_call(stop, _) ->
    {ok, stop}.



send_call_answer({Pid, Ref}, Ans) ->
    Pid ! {answer, Ref, Ans}.

init_limiter_state(Config) ->
    update_limiter_config(#lim{}, Config).


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
     "at all while the rest are limited to rate."].
     
reconfig_action(Lim) ->     
    Lim.

update_limiter_config(Lim, Config) ->
    Lim2 = update_limiter_config_items(Lim, Config),
    reconfig_action(Lim2).

update_limiter_config_items(Lim, Config) ->
    lists:foldl(fun(C, A) -> update_one_config_item(C, A) end,
                Lim,
                Config).

clear_limiter(Lim) ->
    cancel_timer(Lim#lim{level=0}).

cancel_timer(Lim) ->
    Lim.
    
update_one_config_item({rate, Rate}, Lim) ->    
    maybe_update_burst_limit(Lim#lim{rate=Rate});
update_one_config_item({burst_size, Level}, Lim) ->    
    Lim#lim{limit=Level, auto_burst_limit=false};
update_one_config_item(auto_burst_size, Lim) -> 
    maybe_update_burst_limit(Lim#lim{auto_burst_limit=true});
update_one_config_item({period, Time}, Lim) -> 
    Lim#lim{period=Time};
update_one_config_item({state, State}, Lim) -> 
    clear_limiter(Lim#lim{state=State});
update_one_config_item(manual_tick, Lim) -> 
    Lim#lim{manual_tick=true};
update_one_config_item(_, Lim) -> 
    Lim.

maybe_update_burst_limit(Lim=#lim{rate=Rate, auto_burst_limit=true}) ->
    Lim#lim{limit=Rate};
maybe_update_burst_limit(Lim) ->
    Lim.

is_limiter_running(Name) ->    
    is_pid(limiter_pid(Name)).

ins_pid(Name, Pid, Config) ->
    ets:insert(pid_table_name(), [#sysRate{name=Name, pid=Pid, config=Config},
                                  #sysRate{name=Pid, pid=Name}]).

lookup_limiter_by_pid(Pid) ->
    case pid_tab_lookup(Pid) of
        #sysRate{pid=Name} -> pid_tab_lookup(Name);
        _ -> undefined
    end.

pid_tab_lookup(Key) ->
    case ets:lookup(pid_table_name(), Key) of
        [R] -> R;
        _ -> undefined
    end.

del_hanging_pid_item(Pid) ->
    ets:delete(pid_table_name(), Pid).

new_pid_table() ->
    ets:new(pid_table_name(), [set, public, named_table, 
                               {keypos, #sysRate.name}]).    

del_all_pids() ->
    [stop_limiter(R#sysRate.pid) || R <- all_limiters()].

all_limiters() ->
    [Lim  || Lim <- all_table(), is_pid(Lim#sysRate.pid)].

all_table() ->
    ets:tab2list(pid_table_name()).


pid_table_name() ->
    sysRate_pids.


%%------------------
%% Lowlevel bucket stuff

is_bucket_below_limit(#lim{state=on, level=Level, limit=Limit}) 
  when Level >= Limit ->
    false;
is_bucket_below_limit(_) ->
    true.

inc_bucket_level(Lim=#lim{level=Level}) ->
    Lim#lim{level=Level+1}.

timer_tick(Lim=#lim{manual_tick=true}) ->
    leak(timestamp_for_tick(Lim), Lim).

leak(NewTS, Lim=#lim{level=Level}) ->
    Leak = calc_leak(NewTS, Lim),
    NewLevel = max((Level-Leak), 0),
    Lim#lim{leak_ts=NewTS, level=NewLevel}.

calc_leak(NewTS, #lim{leak_ts=OldTS, rate=Rate}) ->
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
    add_the_counters(all_limiters()).

add_the_counters(L) ->
    [{X, read_counters(X#sysRate.pid)} || X <- L].
    

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
    element(3, ts()) div 1000.
ts() ->
    os:timestamp().




