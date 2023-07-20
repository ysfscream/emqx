%%--------------------------------------------------------------------
%% Copyright (c) 2017-2023 EMQ Technologies Co., Ltd. All Rights Reserved.
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
%%--------------------------------------------------------------------

%%--------------------------------------------------------------------
%% @doc
%% A stateful interaction between a Client and a Server. Some Sessions
%% last only as long as the Network Connection, others can span multiple
%% consecutive Network Connections between a Client and a Server.
%%
%% The Session State in the Server consists of:
%%
%% The existence of a Session, even if the rest of the Session State is empty.
%%
%% The Clients subscriptions, including any Subscription Identifiers.
%%
%% QoS 1 and QoS 2 messages which have been sent to the Client, but have not
%% been completely acknowledged.
%%
%% QoS 1 and QoS 2 messages pending transmission to the Client and OPTIONALLY
%% QoS 0 messages pending transmission to the Client.
%%
%% QoS 2 messages which have been received from the Client, but have not been
%% completely acknowledged.The Will Message and the Will Delay Interval
%%
%% If the Session is currently not connected, the time at which the Session
%% will end and Session State will be discarded.
%% @end
%%--------------------------------------------------------------------

%% MQTT Session implementation
%% State is stored in-memory in the process heap.
-module(emqx_session_mem).

-include("emqx.hrl").
-include("emqx_mqtt.hrl").
-include("emqx_session_mem.hrl").
-include("logger.hrl").
-include("types.hrl").

-ifdef(TEST).
-compile(export_all).
-compile(nowarn_export_all).
-endif.

-export([
    lookup/1,
    destroy/1
]).

-export([
    create/3,
    open/2
]).

-export([
    info/2,
    stats/1,
    obtain_next_pkt_id/1
]).

-export([
    subscribe/3,
    unsubscribe/2,
    get_subscription/2
]).

-export([
    publish/3,
    puback/3,
    pubrec/2,
    pubrel/2,
    pubcomp/3
]).

-export([
    deliver/3,
    replay/3,
    handle_timeout/3,
    disconnect/1,
    terminate/2
]).

-export([
    retry/2,
    expire/2
]).

%% Part of takeover sequence
-export([
    takeover/1,
    resume/2,
    enqueue/3,
    dequeue/2,
    replay/2
]).

%% Export for CT
-export([set_field/3]).

-type session_id() :: emqx_guid:guid().

-export_type([
    session/0,
    session_id/0
]).

-type inflight_data_phase() :: wait_ack | wait_comp.

-record(inflight_data, {
    phase :: inflight_data_phase(),
    message :: emqx_types:message(),
    timestamp :: non_neg_integer()
}).

-type session() :: #session{}.

-type clientinfo() :: emqx_types:clientinfo().
-type conninfo() :: emqx_session:conninfo().
-type replies() :: emqx_session:replies().

-define(STATS_KEYS, [
    subscriptions_cnt,
    subscriptions_max,
    inflight_cnt,
    inflight_max,
    mqueue_len,
    mqueue_max,
    mqueue_dropped,
    next_pkt_id,
    awaiting_rel_cnt,
    awaiting_rel_max
]).

-define(DEFAULT_BATCH_N, 1000).

%%--------------------------------------------------------------------
%% Init a Session
%%--------------------------------------------------------------------

-spec create(clientinfo(), conninfo(), emqx_session:conf()) ->
    session().
create(#{zone := Zone, clientid := ClientId}, #{expiry_interval := EI}, Conf) ->
    QueueOpts = get_mqueue_conf(Zone),
    #session{
        id = emqx_guid:gen(),
        clientid = ClientId,
        created_at = erlang:system_time(millisecond),
        is_persistent = EI > 0,
        subscriptions = #{},
        inflight = emqx_inflight:new(maps:get(max_inflight, Conf)),
        mqueue = emqx_mqueue:init(QueueOpts),
        next_pkt_id = 1,
        awaiting_rel = #{},
        timers = #{},
        max_subscriptions = maps:get(max_subscriptions, Conf),
        max_awaiting_rel = maps:get(max_awaiting_rel, Conf),
        upgrade_qos = maps:get(upgrade_qos, Conf),
        retry_interval = maps:get(retry_interval, Conf),
        await_rel_timeout = maps:get(await_rel_timeout, Conf)
    }.

get_mqueue_conf(Zone) ->
    #{
        max_len => get_mqtt_conf(Zone, max_mqueue_len, 1000),
        store_qos0 => get_mqtt_conf(Zone, mqueue_store_qos0),
        priorities => get_mqtt_conf(Zone, mqueue_priorities),
        default_priority => get_mqtt_conf(Zone, mqueue_default_priority)
    }.

get_mqtt_conf(Zone, Key) ->
    emqx_config:get_zone_conf(Zone, [mqtt, Key]).

get_mqtt_conf(Zone, Key, Default) ->
    emqx_config:get_zone_conf(Zone, [mqtt, Key], Default).

-spec lookup(emqx_types:clientinfo()) -> none.
lookup(_ClientInfo) ->
    % NOTE
    % This is a stub. This session impl has no backing store, thus always `none`.
    none.

-spec destroy(session() | clientinfo()) -> ok.
destroy(_Session) ->
    % NOTE
    % This is a stub. This session impl has no backing store, thus always `ok`.
    ok.

%%--------------------------------------------------------------------
%% Open a (possibly existing) Session
%%--------------------------------------------------------------------

-spec open(clientinfo(), emqx_types:conninfo()) ->
    {true, session(), _ReplayContext :: [emqx_types:message()]} | false.
open(ClientInfo = #{clientid := ClientId}, _ConnInfo) ->
    case
        emqx_cm:takeover_channel_session(
            ClientId,
            fun(Session) -> resume(ClientInfo, Session) end
        )
    of
        {ok, Session, Pendings} ->
            clean_session(ClientInfo, Session, Pendings);
        {error, _} ->
            % TODO log error?
            false;
        none ->
            false
    end.

clean_session(ClientInfo, Session = #session{mqueue = Q}, Pendings) ->
    Q1 = emqx_mqueue:filter(fun emqx_session:should_discard/1, Q),
    Session1 = Session#session{mqueue = Q1},
    Pendings1 = emqx_session:enrich_delivers(ClientInfo, Pendings, Session),
    Pendings2 = lists:filter(fun emqx_session:should_discard/1, Pendings1),
    {true, Session1, Pendings2}.

%%--------------------------------------------------------------------
%% Info, Stats
%%--------------------------------------------------------------------

%% @doc Get infos of the session.
info(Keys, Session) when is_list(Keys) ->
    [{Key, info(Key, Session)} || Key <- Keys];
info(id, #session{id = Id}) ->
    Id;
info(clientid, #session{clientid = ClientId}) ->
    ClientId;
info(created_at, #session{created_at = CreatedAt}) ->
    CreatedAt;
info(is_persistent, #session{is_persistent = IsPersistent}) ->
    IsPersistent;
info(subscriptions, #session{subscriptions = Subs}) ->
    Subs;
info(subscriptions_cnt, #session{subscriptions = Subs}) ->
    maps:size(Subs);
info(subscriptions_max, #session{max_subscriptions = MaxSubs}) ->
    MaxSubs;
info(upgrade_qos, #session{upgrade_qos = UpgradeQoS}) ->
    UpgradeQoS;
info(inflight, #session{inflight = Inflight}) ->
    Inflight;
info(inflight_cnt, #session{inflight = Inflight}) ->
    emqx_inflight:size(Inflight);
info(inflight_max, #session{inflight = Inflight}) ->
    emqx_inflight:max_size(Inflight);
info(retry_interval, #session{retry_interval = Interval}) ->
    Interval;
info(mqueue, #session{mqueue = MQueue}) ->
    MQueue;
info(mqueue_len, #session{mqueue = MQueue}) ->
    emqx_mqueue:len(MQueue);
info(mqueue_max, #session{mqueue = MQueue}) ->
    emqx_mqueue:max_len(MQueue);
info(mqueue_dropped, #session{mqueue = MQueue}) ->
    emqx_mqueue:dropped(MQueue);
info(next_pkt_id, #session{next_pkt_id = PacketId}) ->
    PacketId;
info(awaiting_rel, #session{awaiting_rel = AwaitingRel}) ->
    AwaitingRel;
info(awaiting_rel_cnt, #session{awaiting_rel = AwaitingRel}) ->
    maps:size(AwaitingRel);
info(awaiting_rel_max, #session{max_awaiting_rel = Max}) ->
    Max;
info(await_rel_timeout, #session{await_rel_timeout = Timeout}) ->
    Timeout.

%% @doc Get stats of the session.
-spec stats(session()) -> emqx_types:stats().
stats(Session) -> info(?STATS_KEYS, Session).

%%--------------------------------------------------------------------
%% Client -> Broker: SUBSCRIBE / UNSUBSCRIBE
%%--------------------------------------------------------------------

-spec subscribe(emqx_types:topic(), emqx_types:subopts(), session()) ->
    {ok, session()} | {error, emqx_types:reason_code()}.
subscribe(
    TopicFilter,
    SubOpts,
    Session = #session{clientid = ClientId, subscriptions = Subs}
) ->
    IsNew = not maps:is_key(TopicFilter, Subs),
    case IsNew andalso is_subscriptions_full(Session) of
        false ->
            ok = emqx_broker:subscribe(TopicFilter, ClientId, SubOpts),
            Session1 = Session#session{subscriptions = maps:put(TopicFilter, SubOpts, Subs)},
            {ok, Session1};
        true ->
            {error, ?RC_QUOTA_EXCEEDED}
    end.

is_subscriptions_full(#session{max_subscriptions = infinity}) ->
    false;
is_subscriptions_full(#session{
    subscriptions = Subs,
    max_subscriptions = MaxLimit
}) ->
    maps:size(Subs) >= MaxLimit.

-spec unsubscribe(emqx_types:topic(), session()) ->
    {ok, session(), emqx_types:subopts()} | {error, emqx_types:reason_code()}.
unsubscribe(
    TopicFilter,
    Session = #session{subscriptions = Subs}
) ->
    case maps:find(TopicFilter, Subs) of
        {ok, SubOpts} ->
            ok = emqx_broker:unsubscribe(TopicFilter),
            {ok, Session#session{subscriptions = maps:remove(TopicFilter, Subs)}, SubOpts};
        error ->
            {error, ?RC_NO_SUBSCRIPTION_EXISTED}
    end.

-spec get_subscription(emqx_types:topic(), session()) ->
    emqx_types:subopts() | undefined.
get_subscription(Topic, #session{subscriptions = Subs}) ->
    maps:get(Topic, Subs, undefined).

%%--------------------------------------------------------------------
%% Client -> Broker: PUBLISH
%%--------------------------------------------------------------------

-spec publish(emqx_types:packet_id(), emqx_types:message(), session()) ->
    {ok, emqx_types:publish_result(), session()}
    | {error, emqx_types:reason_code()}.
publish(
    PacketId,
    Msg = #message{qos = ?QOS_2, timestamp = Ts},
    Session = #session{awaiting_rel = AwaitingRel, await_rel_timeout = Timeout}
) ->
    case is_awaiting_full(Session) of
        false ->
            case maps:is_key(PacketId, AwaitingRel) of
                false ->
                    Results = emqx_broker:publish(Msg),
                    AwaitingRel1 = maps:put(PacketId, Ts, AwaitingRel),
                    Session1 = ensure_timer(expire_awaiting_rel, Timeout, Session),
                    {ok, Results, Session1#session{awaiting_rel = AwaitingRel1}};
                true ->
                    {error, ?RC_PACKET_IDENTIFIER_IN_USE}
            end;
        true ->
            {error, ?RC_RECEIVE_MAXIMUM_EXCEEDED}
    end;
%% Publish QoS0/1 directly
publish(_PacketId, Msg, Session) ->
    {ok, emqx_broker:publish(Msg), [], Session}.

is_awaiting_full(#session{max_awaiting_rel = infinity}) ->
    false;
is_awaiting_full(#session{
    awaiting_rel = AwaitingRel,
    max_awaiting_rel = MaxLimit
}) ->
    maps:size(AwaitingRel) >= MaxLimit.

%%--------------------------------------------------------------------
%% Client -> Broker: PUBACK
%%--------------------------------------------------------------------

-spec puback(clientinfo(), emqx_types:packet_id(), session()) ->
    {ok, emqx_types:message(), replies(), session()}
    | {error, emqx_types:reason_code()}.
puback(ClientInfo, PacketId, Session = #session{inflight = Inflight}) ->
    case emqx_inflight:lookup(PacketId, Inflight) of
        {value, #inflight_data{phase = wait_ack, message = Msg}} ->
            Inflight1 = emqx_inflight:delete(PacketId, Inflight),
            Session1 = Session#session{inflight = Inflight1},
            {ok, Replies, Session2} = dequeue(ClientInfo, Session1),
            {ok, Msg, Replies, Session2};
        {value, _} ->
            {error, ?RC_PACKET_IDENTIFIER_IN_USE};
        none ->
            {error, ?RC_PACKET_IDENTIFIER_NOT_FOUND}
    end.

%%--------------------------------------------------------------------
%% Client -> Broker: PUBREC
%%--------------------------------------------------------------------

-spec pubrec(emqx_types:packet_id(), session()) ->
    {ok, emqx_types:message(), session()}
    | {error, emqx_types:reason_code()}.
pubrec(PacketId, Session = #session{inflight = Inflight}) ->
    case emqx_inflight:lookup(PacketId, Inflight) of
        {value, #inflight_data{phase = wait_ack, message = Msg} = Data} ->
            Update = Data#inflight_data{phase = wait_comp},
            Inflight1 = emqx_inflight:update(PacketId, Update, Inflight),
            {ok, Msg, Session#session{inflight = Inflight1}};
        {value, _} ->
            {error, ?RC_PACKET_IDENTIFIER_IN_USE};
        none ->
            {error, ?RC_PACKET_IDENTIFIER_NOT_FOUND}
    end.

%%--------------------------------------------------------------------
%% Client -> Broker: PUBREL
%%--------------------------------------------------------------------

-spec pubrel(emqx_types:packet_id(), session()) ->
    {ok, session()}
    | {error, emqx_types:reason_code()}.
pubrel(PacketId, Session = #session{awaiting_rel = AwaitingRel}) ->
    case maps:take(PacketId, AwaitingRel) of
        {_Ts, AwaitingRel1} ->
            NSession = Session#session{awaiting_rel = AwaitingRel1},
            {ok, reconcile_expire_timer(NSession)};
        error ->
            {error, ?RC_PACKET_IDENTIFIER_NOT_FOUND}
    end.

%%--------------------------------------------------------------------
%% Client -> Broker: PUBCOMP
%%--------------------------------------------------------------------

-spec pubcomp(clientinfo(), emqx_types:packet_id(), session()) ->
    {ok, emqx_types:message(), replies(), session()}
    | {error, emqx_types:reason_code()}.
pubcomp(ClientInfo, PacketId, Session = #session{inflight = Inflight}) ->
    case emqx_inflight:lookup(PacketId, Inflight) of
        {value, #inflight_data{phase = wait_comp, message = Msg}} ->
            Inflight1 = emqx_inflight:delete(PacketId, Inflight),
            Session1 = Session#session{inflight = Inflight1},
            {ok, Replies, Session2} = dequeue(ClientInfo, Session1),
            {ok, Msg, Replies, Session2};
        {value, _Other} ->
            {error, ?RC_PACKET_IDENTIFIER_IN_USE};
        none ->
            {error, ?RC_PACKET_IDENTIFIER_NOT_FOUND}
    end.

%%--------------------------------------------------------------------
%% Dequeue Msgs
%%--------------------------------------------------------------------

dequeue(ClientInfo, Session = #session{inflight = Inflight, mqueue = Q}) ->
    case emqx_mqueue:is_empty(Q) of
        true ->
            {ok, [], reconcile_retry_timer(Session)};
        false ->
            {Msgs, Q1} = dequeue(ClientInfo, batch_n(Inflight), [], Q),
            do_deliver(ClientInfo, Msgs, [], Session#session{mqueue = Q1})
    end.

dequeue(_ClientInfo, 0, Msgs, Q) ->
    {lists:reverse(Msgs), Q};
dequeue(ClientInfo, Cnt, Msgs, Q) ->
    case emqx_mqueue:out(Q) of
        {empty, _Q} ->
            dequeue(ClientInfo, 0, Msgs, Q);
        {{value, Msg}, Q1} ->
            case emqx_message:is_expired(Msg) of
                true ->
                    _ = emqx_session_events:handle_event(ClientInfo, {expired, Msg}),
                    dequeue(ClientInfo, Cnt, Msgs, Q1);
                false ->
                    dequeue(ClientInfo, acc_cnt(Msg, Cnt), [Msg | Msgs], Q1)
            end
    end.

acc_cnt(#message{qos = ?QOS_0}, Cnt) -> Cnt;
acc_cnt(_Msg, Cnt) -> Cnt - 1.

%%--------------------------------------------------------------------
%% Broker -> Client: Deliver
%%--------------------------------------------------------------------

-spec deliver(clientinfo(), [emqx_types:deliver()], session()) ->
    {ok, replies(), session()}.
deliver(ClientInfo, Msgs, Session) ->
    do_deliver(ClientInfo, Msgs, [], Session).

do_deliver(_ClientInfo, [], Publishes, Session) ->
    {ok, lists:reverse(Publishes), reconcile_retry_timer(Session)};
do_deliver(ClientInfo, [Msg | More], Acc, Session) ->
    case deliver_msg(ClientInfo, Msg, Session) of
        {ok, [], Session1} ->
            do_deliver(ClientInfo, More, Acc, Session1);
        {ok, [Publish], Session1} ->
            do_deliver(ClientInfo, More, [Publish | Acc], Session1)
    end.

deliver_msg(_ClientInfo, Msg = #message{qos = ?QOS_0}, Session) ->
    {ok, [{undefined, maybe_ack(Msg)}], Session};
deliver_msg(
    ClientInfo,
    Msg = #message{qos = QoS},
    Session = #session{next_pkt_id = PacketId, inflight = Inflight}
) when
    QoS =:= ?QOS_1 orelse QoS =:= ?QOS_2
->
    case emqx_inflight:is_full(Inflight) of
        true ->
            Session1 =
                case maybe_nack(Msg) of
                    true -> Session;
                    false -> enqueue_msg(ClientInfo, Msg, Session)
                end,
            {ok, [], Session1};
        false ->
            %% Note that we publish message without shared ack header
            %% But add to inflight with ack headers
            %% This ack header is required for redispatch-on-terminate feature to work
            Publish = {PacketId, maybe_ack(Msg)},
            MarkedMsg = mark_begin_deliver(Msg),
            Inflight1 = emqx_inflight:insert(PacketId, with_ts(MarkedMsg), Inflight),
            {ok, [Publish], next_pkt_id(Session#session{inflight = Inflight1})}
    end.

-spec enqueue(clientinfo(), [emqx_types:message()], session()) ->
    session().
enqueue(ClientInfo, Msgs, Session) when is_list(Msgs) ->
    lists:foldl(
        fun(Msg, Session0) -> enqueue_msg(ClientInfo, Msg, Session0) end,
        Session,
        Msgs
    ).

enqueue_msg(ClientInfo, #message{qos = QOS} = Msg, Session = #session{mqueue = Q}) ->
    {Dropped, NewQ} = emqx_mqueue:in(Msg, Q),
    case Dropped of
        undefined ->
            Session#session{mqueue = NewQ};
        _Msg ->
            Reason =
                case emqx_mqueue:info(store_qos0, Q) of
                    false when QOS =:= ?QOS_0 -> qos0_msg;
                    _ -> queue_full
                end,
            _ = emqx_session_events:handle_event(ClientInfo, {dropped, Dropped, Reason}),
            Session
    end.

maybe_ack(Msg) ->
    emqx_shared_sub:maybe_ack(Msg).

maybe_nack(Msg) ->
    emqx_shared_sub:maybe_nack_dropped(Msg).

mark_begin_deliver(Msg) ->
    emqx_message:set_header(deliver_begin_at, erlang:system_time(millisecond), Msg).

%%--------------------------------------------------------------------
%% Timeouts
%%--------------------------------------------------------------------

-spec handle_timeout(clientinfo(), atom(), session()) ->
    {ok, replies(), session()}.
handle_timeout(ClientInfo, retry_delivery = Name, Session) ->
    retry(ClientInfo, clean_timer(Name, Session));
handle_timeout(ClientInfo, expire_awaiting_rel = Name, Session) ->
    expire(ClientInfo, clean_timer(Name, Session)).

%%--------------------------------------------------------------------
%% Retry Delivery
%%--------------------------------------------------------------------

-spec retry(clientinfo(), session()) ->
    {ok, replies(), session()}.
retry(ClientInfo, Session = #session{inflight = Inflight}) ->
    case emqx_inflight:is_empty(Inflight) of
        true ->
            {ok, [], Session};
        false ->
            Now = erlang:system_time(millisecond),
            retry_delivery(
                ClientInfo,
                emqx_inflight:to_list(fun sort_fun/2, Inflight),
                [],
                Now,
                Session
            )
    end.

retry_delivery(_ClientInfo, [], Acc, _Now, Session) ->
    {ok, lists:reverse(Acc), reconcile_retry_timer(Session)};
retry_delivery(
    ClientInfo,
    [{PacketId, #inflight_data{timestamp = Ts} = Data} | More],
    Acc,
    Now,
    Session = #session{retry_interval = Interval, inflight = Inflight}
) ->
    case (Age = age(Now, Ts)) >= Interval of
        true ->
            {Acc1, Inflight1} = do_retry_delivery(ClientInfo, PacketId, Data, Now, Acc, Inflight),
            retry_delivery(ClientInfo, More, Acc1, Now, Session#session{inflight = Inflight1});
        false ->
            NSession = ensure_timer(retry_delivery, Interval - max(0, Age), Session),
            {ok, lists:reverse(Acc), NSession}
    end.

do_retry_delivery(
    ClientInfo,
    PacketId,
    #inflight_data{phase = wait_ack, message = Msg} = Data,
    Now,
    Acc,
    Inflight
) ->
    case emqx_message:is_expired(Msg) of
        true ->
            _ = emqx_session_events:handle_event(ClientInfo, {expired, Msg}),
            {Acc, emqx_inflight:delete(PacketId, Inflight)};
        false ->
            Msg1 = emqx_message:set_flag(dup, true, Msg),
            Update = Data#inflight_data{message = Msg1, timestamp = Now},
            Inflight1 = emqx_inflight:update(PacketId, Update, Inflight),
            {[{PacketId, Msg1} | Acc], Inflight1}
    end;
do_retry_delivery(_ClientInfo, PacketId, Data, Now, Acc, Inflight) ->
    Update = Data#inflight_data{timestamp = Now},
    Inflight1 = emqx_inflight:update(PacketId, Update, Inflight),
    {[{pubrel, PacketId} | Acc], Inflight1}.

%%--------------------------------------------------------------------
%% Expire Awaiting Rel
%%--------------------------------------------------------------------

-spec expire(clientinfo(), session()) ->
    {ok, replies(), session()}.
expire(ClientInfo, Session = #session{awaiting_rel = AwaitingRel}) ->
    case maps:size(AwaitingRel) of
        0 ->
            {ok, [], Session};
        _ ->
            Now = erlang:system_time(millisecond),
            NSession = expire_awaiting_rel(ClientInfo, Now, Session),
            {ok, [], reconcile_expire_timer(NSession)}
    end.

expire_awaiting_rel(
    ClientInfo,
    Now,
    Session = #session{awaiting_rel = AwaitingRel, await_rel_timeout = Timeout}
) ->
    NotExpired = fun(_PacketId, Ts) -> age(Now, Ts) < Timeout end,
    AwaitingRel1 = maps:filter(NotExpired, AwaitingRel),
    ExpiredCnt = maps:size(AwaitingRel) - maps:size(AwaitingRel1),
    _ = emqx_session_events:handle_event(ClientInfo, {expired_rel, ExpiredCnt}),
    Session#session{awaiting_rel = AwaitingRel1}.

%%--------------------------------------------------------------------
%% Takeover, Resume and Replay
%%--------------------------------------------------------------------

-spec takeover(session()) ->
    ok.
takeover(#session{subscriptions = Subs}) ->
    lists:foreach(fun emqx_broker:unsubscribe/1, maps:keys(Subs)).

-spec resume(emqx_types:clientinfo(), session()) ->
    session().
resume(ClientInfo = #{clientid := ClientId}, Session = #session{subscriptions = Subs}) ->
    ok = maps:foreach(
        fun(TopicFilter, SubOpts) ->
            ok = emqx_broker:subscribe(TopicFilter, ClientId, SubOpts)
        end,
        Subs
    ),
    ok = emqx_metrics:inc('session.resumed'),
    ok = emqx_hooks:run('session.resumed', [ClientInfo, emqx_session:info(Session)]),
    Session#session{timers = #{}}.

-spec replay(emqx_types:clientinfo(), [emqx_types:message()], session()) ->
    {ok, replies(), session()}.
replay(ClientInfo, Pendings, Session) ->
    PendingsLocal = emqx_session:enrich_delivers(
        ClientInfo,
        emqx_utils:drain_deliver(),
        Session
    ),
    PendingsLocal1 = lists:filter(
        fun(Msg) -> not lists:keymember(Msg#message.id, #message.id, Pendings) end,
        PendingsLocal
    ),
    {ok, PubsResendQueued, Session1} = replay(ClientInfo, Session),
    {ok, Pubs1, Session2} = deliver(ClientInfo, Pendings, Session1),
    {ok, Pubs2, Session3} = deliver(ClientInfo, PendingsLocal1, Session2),
    {ok, append(append(PubsResendQueued, Pubs1), Pubs2), Session3}.

-spec replay(emqx_types:clientinfo(), session()) ->
    {ok, replies(), session()}.
replay(ClientInfo, Session) ->
    PubsResend = lists:map(
        fun
            ({PacketId, #inflight_data{phase = wait_comp}}) ->
                {pubrel, PacketId};
            ({PacketId, #inflight_data{message = Msg}}) ->
                {PacketId, emqx_message:set_flag(dup, true, Msg)}
        end,
        emqx_inflight:to_list(Session#session.inflight)
    ),
    {ok, More, Session1} = dequeue(ClientInfo, Session),
    {ok, append(PubsResend, More), reconcile_expire_timer(Session1)}.

append(L1, []) -> L1;
append(L1, L2) -> L1 ++ L2.

%%--------------------------------------------------------------------

-spec disconnect(session()) -> {idle, session()}.
disconnect(Session = #session{}) ->
    % TODO: isolate expiry timer / timeout handling here?
    {idle, cancel_timers(Session)}.

-spec terminate(Reason :: term(), session()) -> ok.
terminate(Reason, Session) ->
    maybe_redispatch_shared_messages(Reason, Session),
    ok.

maybe_redispatch_shared_messages(takenover, _Session) ->
    ok;
maybe_redispatch_shared_messages(kicked, _Session) ->
    ok;
maybe_redispatch_shared_messages(_Reason, Session) ->
    redispatch_shared_messages(Session).

redispatch_shared_messages(#session{inflight = Inflight, mqueue = Q}) ->
    AllInflights = emqx_inflight:to_list(fun sort_fun/2, Inflight),
    F = fun
        ({_PacketId, #inflight_data{message = #message{qos = ?QOS_1} = Msg}}) ->
            %% For QoS 2, here is what the spec says:
            %% If the Client's Session terminates before the Client reconnects,
            %% the Server MUST NOT send the Application Message to any other
            %% subscribed Client [MQTT-4.8.2-5].
            {true, Msg};
        ({_PacketId, #inflight_data{}}) ->
            false
    end,
    InflightList = lists:filtermap(F, AllInflights),
    emqx_shared_sub:redispatch(InflightList ++ emqx_mqueue:to_list(Q)).

%%--------------------------------------------------------------------
%% Next Packet Id
%%--------------------------------------------------------------------

obtain_next_pkt_id(Session) ->
    {Session#session.next_pkt_id, next_pkt_id(Session)}.

next_pkt_id(Session = #session{next_pkt_id = ?MAX_PACKET_ID}) ->
    Session#session{next_pkt_id = 1};
next_pkt_id(Session = #session{next_pkt_id = Id}) ->
    Session#session{next_pkt_id = Id + 1}.

%%--------------------------------------------------------------------
%% Helper functions
%%--------------------------------------------------------------------

-compile({inline, [sort_fun/2, batch_n/1, with_ts/1, age/2]}).

sort_fun({_, A}, {_, B}) ->
    A#inflight_data.timestamp =< B#inflight_data.timestamp.

batch_n(Inflight) ->
    case emqx_inflight:max_size(Inflight) of
        0 -> ?DEFAULT_BATCH_N;
        Sz -> Sz - emqx_inflight:size(Inflight)
    end.

with_ts(Msg) ->
    #inflight_data{
        phase = wait_ack,
        message = Msg,
        timestamp = erlang:system_time(millisecond)
    }.

age(Now, Ts) -> Now - Ts.

%%--------------------------------------------------------------------

reconcile_retry_timer(Session = #session{inflight = Inflight}) ->
    case emqx_inflight:is_empty(Inflight) of
        false ->
            ensure_timer(retry_delivery, Session#session.retry_interval, Session);
        true ->
            cancel_timer(retry_delivery, Session)
    end.

reconcile_expire_timer(Session = #session{awaiting_rel = AwaitingRel}) ->
    case maps:size(AwaitingRel) of
        0 ->
            cancel_timer(expire_awaiting_rel, Session);
        _ ->
            ensure_timer(expire_awaiting_rel, Session#session.await_rel_timeout, Session)
    end.

%%--------------------------------------------------------------------

ensure_timer(Name, Timeout, Session = #session{timers = Timers}) ->
    NTimers = emqx_session:ensure_timer(Name, Timeout, Timers),
    Session#session{timers = NTimers}.

clean_timer(Name, Session = #session{timers = Timers}) ->
    Session#session{timers = maps:remove(Name, Timers)}.

cancel_timers(Session = #session{timers = Timers}) ->
    ok = maps:foreach(fun(_Name, TRef) -> emqx_utils:cancel_timer(TRef) end, Timers),
    Session#session{timers = #{}}.

cancel_timer(Name, Session = #session{timers = Timers}) ->
    Session#session{timers = emqx_session:cancel_timer(Name, Timers)}.

%%--------------------------------------------------------------------
%% For CT tests
%%--------------------------------------------------------------------

set_field(Name, Value, Session) ->
    Pos = emqx_utils:index_of(Name, record_info(fields, session)),
    setelement(Pos + 1, Session, Value).
