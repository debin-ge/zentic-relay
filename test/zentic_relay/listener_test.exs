defmodule ZenticRelay.ListenerTest do
  use ExUnit.Case, async: false

  import Bitwise

  @capacity_mutation_timeout_ms ZenticRelay.Config.defaults().capacity_mutation_timeout_ms

  setup do
    assert ZenticRelay.Metrics.value(:active_websockets) == 0

    on_exit(fn ->
      assert_eventually(fn -> ZenticRelay.Metrics.value(:active_websockets) == 0 end)
    end)

    :ok
  end

  test "the native Cowboy listener serves relay operations" do
    listener = {:listener_test, System.unique_integer([:positive])}

    start_supervised!(
      {ZenticRelay.Listener,
       ref: listener,
       config: ZenticRelay.Config.defaults(),
       ip: {127, 0, 0, 1},
       port: 0,
       acceptors: 1,
       max_connections: 10}
    )

    port = ZenticRelay.Listener.port(listener)
    {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false])
    :ok = :gen_tcp.send(socket, "GET /health HTTP/1.1\r\nHost: relay.test\r\n\r\n")
    {:ok, response} = :gen_tcp.recv(socket, 0, 2_000)

    assert response =~ "HTTP/1.1 200 OK"
    assert response =~ ~s({"status":"ok"})
  end

  test "a stalled HTTP body releases its listener slot without expiring WebSockets" do
    listener = {:listener_http_idle, System.unique_integer([:positive])}

    start_supervised!(
      {ZenticRelay.Listener,
       ref: listener,
       config: ZenticRelay.Config.defaults(),
       ip: {127, 0, 0, 1},
       port: 0,
       acceptors: 1,
       connection_supervisors: 1,
       max_connections: 1,
       http_idle_timeout_ms: 100}
    )

    port = ZenticRelay.Listener.port(listener)
    {:ok, stalled} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false])

    on_exit(fn ->
      :gen_tcp.close(stalled)
    end)

    :ok =
      :gen_tcp.send(
        stalled,
        "POST /health HTTP/1.1\r\nHost: relay.test\r\nContent-Length: 1\r\n\r\n"
      )

    assert {:ok, stalled_response} = :gen_tcp.recv(stalled, 0, 2_000)
    assert stalled_response =~ "HTTP/1.1 200 OK"

    {:ok, health} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false])
    on_exit(fn -> :gen_tcp.close(health) end)
    :ok = :gen_tcp.send(health, "GET /health HTTP/1.1\r\nHost: relay.test\r\n\r\n")
    assert {:ok, response} = :gen_tcp.recv(health, 0, 2_000)
    assert response =~ "HTTP/1.1 200 OK"
    :ok = :gen_tcp.close(health)

    websocket = open_websocket(port, "http-timeout-websocket")
    on_exit(fn -> :gen_tcp.close(websocket) end)
    Process.sleep(200)
    :ok = :gen_tcp.send(websocket, :cow_ws.masked_frame({:ping, "alive"}, 0x10203040))
    assert {:pong, "alive"} = recv_until_pong(websocket, "alive")
  end

  test "the active WebSocket ceiling rejects exactly at capacity and releases on close" do
    reference = {:listener_budget, System.unique_integer([:positive])}
    rejections = ZenticRelay.Metrics.value(:connection_rejections)

    start_supervised!(
      {ZenticRelay.Listener,
       ref: reference,
       config: ZenticRelay.Config.defaults(),
       ip: {127, 0, 0, 1},
       port: 0,
       acceptors: 2,
       max_connections: 100,
       max_websockets: 2}
    )

    port = ZenticRelay.Listener.port(reference)
    rejected_server_id = "budget-third-#{System.unique_integer([:positive])}"
    first = open_websocket(port, "budget-first")
    second = open_websocket(port, "budget-second")

    assert ZenticRelay.Capacity.active_connections(reference) == 2
    assert http_get(port, "/ready") =~ "HTTP/1.1 503 Service Unavailable"

    rejected = connect_and_request_websocket(port, rejected_server_id)
    assert {:ok, response} = :gen_tcp.recv(rejected, 0, 2_000)
    assert response =~ "HTTP/1.1 503 Service Unavailable"
    assert response =~ "Relay connection capacity"
    assert ZenticRelay.Metrics.value(:connection_rejections) == rejections + 1
    assert ZenticRelay.Ownership.resolve(rejected_server_id) == :unowned
    :ok = :gen_tcp.close(rejected)

    :ok = :gen_tcp.close(first)
    assert_eventually(fn -> ZenticRelay.Capacity.active_connections(reference) == 1 end)
    assert http_get(port, "/ready") =~ "HTTP/1.1 200 OK"

    replacement = open_websocket(port, rejected_server_id)
    assert ZenticRelay.Capacity.active_connections(reference) == 2

    :ok = :gen_tcp.close(second)
    :ok = :gen_tcp.close(replacement)
    assert_eventually(fn -> ZenticRelay.Capacity.active_connections(reference) == 0 end)
  end

  @tag timeout: 15_000
  test "a timed-out upgrade invalidates its Capacity and listener epoch" do
    reference = ZenticRelay.Listener
    port = ZenticRelay.Listener.port(reference)
    initial_connections = MapSet.new(:ranch.procs(reference, :connections))
    established = open_websocket(port, "stalled-capacity-existing")

    assert_eventually(fn ->
      reference
      |> :ranch.procs(:connections)
      |> MapSet.new()
      |> MapSet.difference(initial_connections)
      |> MapSet.size() == 1
    end)

    [established_connection] =
      reference
      |> :ranch.procs(:connections)
      |> MapSet.new()
      |> MapSet.difference(initial_connections)
      |> MapSet.to_list()

    established_monitor = Process.monitor(established_connection)
    capacity = Process.whereis(ZenticRelay.Capacity)
    listener = runtime_child(ZenticRelay.Listener)
    existing_connections = MapSet.new(:ranch.procs(reference, :connections))
    capacity_monitor = Process.monitor(capacity)
    listener_monitor = Process.monitor(listener)
    :ok = :sys.suspend(capacity)

    on_exit(fn ->
      if Process.alive?(capacity), do: :sys.resume(capacity)
    end)

    socket = connect_and_request_websocket(port, "stalled-capacity-command")

    assert_eventually(fn ->
      reference
      |> :ranch.procs(:connections)
      |> MapSet.new()
      |> MapSet.difference(existing_connections)
      |> MapSet.size() == 1
    end)

    [connection] =
      reference
      |> :ranch.procs(:connections)
      |> MapSet.new()
      |> MapSet.difference(existing_connections)
      |> MapSet.to_list()

    connection_monitor = Process.monitor(connection)
    assert {:error, :timeout} = :gen_tcp.recv(socket, 0, 4_500)
    assert_receive {:DOWN, ^capacity_monitor, :process, ^capacity, :killed}, 2_000
    assert_receive {:DOWN, ^listener_monitor, :process, ^listener, :shutdown}, 2_000

    assert_receive {:DOWN, ^established_monitor, :process, ^established_connection,
                    _established_reason},
                   2_000

    assert_receive {:DOWN, ^connection_monitor, :process, ^connection, _stalled_reason}, 2_000
    assert_eventually(fn -> Process.whereis(ZenticRelay.Capacity) != capacity end)
    assert_eventually(fn -> runtime_child(ZenticRelay.Listener) != listener end)
    assert ZenticRelay.Capacity.active_connections(reference) == 0
    assert ZenticRelay.Metrics.value(:active_websockets) == 0
    assert ZenticRelay.Ownership.resolve("stalled-capacity-command") == :unowned

    replacement = open_websocket(port, "stalled-capacity-command")

    :ok = :gen_tcp.close(socket)
    :ok = :gen_tcp.close(established)
    :ok = :gen_tcp.close(replacement)
    assert_eventually(fn -> ZenticRelay.Capacity.active_connections(reference) == 0 end)
    assert_eventually(fn -> ZenticRelay.Metrics.value(:active_websockets) == 0 end)
  end

  @tag timeout: 5_000
  test "a caller disconnect during stalled admission leaves no public reservation" do
    reference = {:listener_stalled_disconnect, System.unique_integer([:positive])}

    start_supervised!(
      {ZenticRelay.Listener,
       ref: reference,
       config: ZenticRelay.Config.defaults(),
       ip: {127, 0, 0, 1},
       port: 0,
       acceptors: 1,
       max_connections: 10,
       max_websockets: 1}
    )

    capacity = Process.whereis(ZenticRelay.Capacity)
    :ok = :sys.suspend(capacity)

    on_exit(fn ->
      if Process.alive?(capacity), do: :sys.resume(capacity)
    end)

    socket =
      reference
      |> ZenticRelay.Listener.port()
      |> connect_and_request_websocket("stalled-capacity-disconnect")

    assert {:error, :timeout} = :gen_tcp.recv(socket, 0, 100)
    :ok = :gen_tcp.close(socket)
    assert_eventually(fn -> :ranch.procs(reference, :connections) == [] end)

    :ok = :sys.resume(capacity)

    assert Process.whereis(ZenticRelay.Capacity) == capacity
    assert ZenticRelay.Capacity.active_connections(reference) == 0

    replacement =
      reference
      |> ZenticRelay.Listener.port()
      |> open_websocket("stalled-capacity-replacement")

    :ok = :gen_tcp.close(replacement)
    assert_eventually(fn -> ZenticRelay.Capacity.active_connections(reference) == 0 end)
    assert_eventually(fn -> ZenticRelay.Metrics.value(:active_websockets) == 0 end)
  end

  @tag timeout: 8_000
  test "a timed-out watermark mutation invalidates its Capacity epoch" do
    capacity = Process.whereis(ZenticRelay.Capacity)
    capacity_monitor = Process.monitor(capacity)
    :ok = :sys.suspend(capacity)

    on_exit(fn ->
      if Process.alive?(capacity), do: :sys.resume(capacity)
      ZenticRelay.Capacity.set_watermark(0, @capacity_mutation_timeout_ms)
    end)

    control =
      Task.async(fn ->
        ZenticRelay.Capacity.set_watermark(1, @capacity_mutation_timeout_ms)
      end)

    assert Task.await(control, 6_000) == {:error, :unavailable}
    assert_receive {:DOWN, ^capacity_monitor, :process, ^capacity, :killed}, 2_000

    assert_eventually(fn ->
      replacement = Process.whereis(ZenticRelay.Capacity)
      is_pid(replacement) and replacement != capacity
    end)

    replacement = Process.whereis(ZenticRelay.Capacity)
    assert is_pid(replacement)

    assert {:available, %{admission: :open}} =
             ZenticRelay.Capacity.status(ZenticRelay.Listener, 20_000)
  end

  defp runtime_child(id) do
    ZenticRelay.RuntimeSupervisor
    |> Supervisor.which_children()
    |> Enum.find_value(fn
      {^id, process, _type, _modules} -> process
      _other -> nil
    end)
  end

  test "the active WebSocket gauge reconciles when the heap fuse kills a socket" do
    reference = {:listener_heap_fuse, System.unique_integer([:positive])}
    config = %{ZenticRelay.Config.defaults() | websocket_max_heap_words: 65_536}

    start_supervised!(
      {ZenticRelay.Listener,
       ref: reference,
       config: config,
       ip: {127, 0, 0, 1},
       port: 0,
       acceptors: 1,
       max_connections: 100,
       max_websockets: 2}
    )

    socket = open_websocket(ZenticRelay.Listener.port(reference), "heap-fuse")
    assert_eventually(fn -> ZenticRelay.Metrics.value(:active_websockets) == 1 end)

    payload = :binary.copy(<<0x5A>>, 1024 * 1024)
    :ok = :gen_tcp.send(socket, :cow_ws.masked_frame({:binary, payload}, 0x11223344))

    assert_eventually(fn -> ZenticRelay.Capacity.active_connections(reference) == 0 end)
    assert ZenticRelay.Metrics.value(:active_websockets) == 0
  end

  test "a queued reservation expiry cannot release an attached connection" do
    namespace = {:stale_expiry, System.unique_integer([:positive])}

    assert {:ok, token} =
             ZenticRelay.Capacity.admit_connection(namespace, 1, @capacity_mutation_timeout_ms)

    assert {:ok, _capacity} =
             ZenticRelay.Capacity.attach_connection(token, @capacity_mutation_timeout_ms)

    send(ZenticRelay.Capacity, {:expire, token})

    assert ZenticRelay.Capacity.active_connections(namespace) == 1
    assert :ok = ZenticRelay.Capacity.release_connection(token)
    assert ZenticRelay.Capacity.active_connections(namespace) == 0
  end

  test "pressure shedding makes message admission terminal for the selected socket" do
    namespace = {:shedding_terminal, System.unique_integer([:positive])}
    watermark = ZenticRelay.Config.defaults().memory_watermark_bytes

    on_exit(fn ->
      ZenticRelay.Capacity.set_watermark(watermark, @capacity_mutation_timeout_ms)
    end)

    assert {:ok, connection} =
             ZenticRelay.Capacity.admit_connection(namespace, 1, @capacity_mutation_timeout_ms)

    assert {:ok, _capacity} =
             ZenticRelay.Capacity.attach_connection(connection, @capacity_mutation_timeout_ms)

    assert {:ok, message} =
             ZenticRelay.Capacity.admit_message(1, @capacity_mutation_timeout_ms)

    assert :ok = ZenticRelay.Capacity.set_watermark(1, @capacity_mutation_timeout_ms)
    assert :ok = ZenticRelay.Capacity.check_now(@capacity_mutation_timeout_ms)

    assert {:error, :closed} =
             ZenticRelay.Capacity.admit_message(1, @capacity_mutation_timeout_ms)

    assert {:error, :closed} =
             ZenticRelay.Capacity.start_delivery(message, @capacity_mutation_timeout_ms)

    assert :ok = ZenticRelay.Capacity.release_connection(connection)
  end

  test "one pressure check sheds enough real sockets for the current memory overshoot" do
    port = ZenticRelay.Listener.port(ZenticRelay.Listener)
    first = open_websocket(port, "pressure-batch-first")
    second = open_websocket(port, "pressure-batch-second")

    assert_eventually(
      fn -> ZenticRelay.Metrics.value(:active_websockets) == 2 end,
      @capacity_mutation_timeout_ms
    )

    padding = :binary.copy(<<0x4D>>, 40 * 1024 * 1024)
    maximum_message = ZenticRelay.Protocol.maximum_message_payload_bytes()
    :erlang.garbage_collect(self())
    watermark = :erlang.memory(:total) - maximum_message - 1
    assert watermark > 0

    on_exit(fn -> ZenticRelay.Capacity.set_watermark(0, @capacity_mutation_timeout_ms) end)
    assert :ok = ZenticRelay.Capacity.set_watermark(watermark, @capacity_mutation_timeout_ms)
    assert :ok = ZenticRelay.Capacity.check_now(@capacity_mutation_timeout_ms)
    assert byte_size(padding) == 40 * 1024 * 1024
    assert :ok = ZenticRelay.Capacity.set_watermark(0, @capacity_mutation_timeout_ms)

    assert_eventually(
      fn -> ZenticRelay.Metrics.value(:active_websockets) == 0 end,
      @capacity_mutation_timeout_ms
    )

    assert {:close, 1013, "Relay memory pressure"} = recv_until_close(first)
    assert {:close, 1013, "Relay memory pressure"} = recv_until_close(second)
  end

  defp open_websocket(port, server_id) do
    socket = connect_and_request_websocket(port, server_id)
    assert {:ok, response} = :gen_tcp.recv(socket, 0, 2_000)
    assert response =~ "HTTP/1.1 101 Switching Protocols"
    socket
  end

  defp connect_and_request_websocket(port, server_id) do
    {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false])
    key = Base.encode64(:crypto.strong_rand_bytes(16))

    request =
      "GET /ws?serverId=#{server_id}&role=server&v=2 HTTP/1.1\r\n" <>
        "Host: relay.test\r\n" <>
        "Upgrade: websocket\r\n" <>
        "Connection: Upgrade\r\n" <>
        "Sec-WebSocket-Version: 13\r\n" <>
        "Sec-WebSocket-Key: #{key}\r\n\r\n"

    :ok = :gen_tcp.send(socket, request)
    socket
  end

  defp http_get(port, path) do
    {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false])
    :ok = :gen_tcp.send(socket, "GET #{path} HTTP/1.0\r\nHost: relay.test\r\n\r\n")
    {:ok, response} = :gen_tcp.recv(socket, 0, 2_000)
    :ok = :gen_tcp.close(socket)
    response
  end

  defp recv_until_close(socket) do
    case recv_server_frame(socket) do
      {:close, _code, _reason} = close -> close
      _frame -> recv_until_close(socket)
    end
  end

  defp recv_until_pong(socket, payload) do
    case recv_server_frame(socket) do
      {:pong, ^payload} = pong -> pong
      _frame -> recv_until_pong(socket, payload)
    end
  end

  defp recv_server_frame(socket) do
    {:ok, <<first, second>>} = :gen_tcp.recv(socket, 2, 2_000)
    opcode = first &&& 0x0F
    length = second &&& 0x7F

    length =
      case length do
        126 ->
          {:ok, <<value::16>>} = :gen_tcp.recv(socket, 2, 2_000)
          value

        127 ->
          {:ok, <<value::64>>} = :gen_tcp.recv(socket, 8, 2_000)
          value

        value ->
          value
      end

    {:ok, payload} = :gen_tcp.recv(socket, length, 2_000)

    case {opcode, payload} do
      {0x8, <<code::16, reason::binary>>} -> {:close, code, reason}
      {0x1, payload} -> {:text, payload}
      {0x2, payload} -> {:binary, payload}
      {0xA, payload} -> {:pong, payload}
    end
  end

  defp assert_eventually(assertion, timeout \\ 2_000) do
    deadline = System.monotonic_time(:millisecond) + timeout

    until_true(assertion, deadline)
  end

  defp until_true(assertion, deadline) do
    if assertion.() do
      :ok
    else
      if System.monotonic_time(:millisecond) >= deadline do
        flunk("condition did not become true before timeout")
      else
        receive do
        after
          10 -> until_true(assertion, deadline)
        end
      end
    end
  end
end
