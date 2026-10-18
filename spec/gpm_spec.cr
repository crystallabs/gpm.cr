require "./spec_helper"

private def event(buttons : GPM::Buttons, types : GPM::Types, modifiers : GPM::Modifiers = GPM::Modifiers::None)
  GPM::Event.new(
    buttons, modifiers,
    1_u16,          # vc
    0_i16, 0_i16,   # dx, dy
    10_i16, 20_i16, # x, y
    types,
    1, # clicks
    GPM::Margins::None,
    0_i16, 0_i16 # wdx, wdy
  )
end

# Serializes an Event the way the daemon writes its Gpm_Event struct.
private def encode(e : GPM::Event) : Bytes
  io = IO::Memory.new 28
  io.write_byte e.buttons.value.to_u8
  io.write_byte e.modifiers.value.to_u8
  {e.vc, e.dx, e.dy, e.x, e.y, e.types.value, e.clicks, e.margins.value, e.wdx, e.wdy}.each do |field|
    io.write_bytes field, GPM::ENDIAN
  end
  io.to_slice
end

# Parses a Gpm_Connect struct as written by `send_config`.
private def decode_config(bytes : Bytes) : GPM::Config
  io = IO::Memory.new bytes
  GPM::Config.new(
    event_mask: GPM::Types.new(io.read_bytes(UInt16, GPM::ENDIAN).to_i32),
    default_mask: GPM::Types.new(io.read_bytes(UInt16, GPM::ENDIAN).to_i32),
    min_mod: io.read_bytes(UInt16, GPM::ENDIAN),
    max_mod: io.read_bytes(UInt16, GPM::ENDIAN),
    pid: io.read_bytes(Int32, GPM::ENDIAN),
    vc: io.read_bytes(Int32, GPM::ENDIAN),
  )
end

# Daemon-free fixture: a throwaway UNIXServer stands in for gpm so the
# constructor's connect and handshake succeed.
private def with_server(&)
  path = File.tempname("gpm-spec", ".sock")
  server = UNIXServer.new(path)
  begin
    yield server, path
  ensure
    server.close
    File.delete(path) if File.exists?(path)
  end
end

# Accepts the client and consumes its handshake, returning the daemon-side
# socket and the raw handshake bytes.
private def accept_handshake(server : UNIXServer, size = 16) : {UNIXSocket, Bytes}
  peer = server.accept
  handshake = Bytes.new size
  peer.read_fully handshake
  {peer, handshake}
end

# Subclass that lets a spec force the in-constructor handshake to fail while
# recording the socket the constructor opened, so we can assert it was closed.
private class FailingGPM < GPM
  class_property captured : UNIXSocket? = nil

  def send_config(config = @config, socket = @socket)
    FailingGPM.captured = @socket
    raise "forced handshake failure"
  end
end

describe GPM do
  describe "#initialize" do
    # The just-opened socket must be closed (not leaked) before a handshake
    # exception escapes the constructor.
    it "closes the opened socket if the initial handshake fails" do
      with_server do |_, path|
        FailingGPM.captured = nil
        expect_raises(Exception, "forced handshake failure") do
          FailingGPM.new(file: path)
        end
        FailingGPM.captured.try(&.closed?).should be_true
      end
    end

    it "sends the given config as the 16-byte Gpm_Connect handshake" do
      with_server do |server, path|
        config = GPM::Config.new(event_mask: GPM::Types::DOWN | GPM::Types::UP, default_mask: GPM::Types::MOVE, min_mod: 1_u16, max_mod: 7_u16, pid: 1234, vc: 3)
        gpm = GPM.new(file: path, config: config)
        _, handshake = accept_handshake(server)
        decode_config(handshake).should eq(config)
        gpm.stop
      end
    end

    it "prefixes the handshake with the magic word when use_magic is set" do
      with_server do |server, path|
        gpm = GPM.new(file: path, use_magic: true)
        _, handshake = accept_handshake(server, 20)
        IO::ByteFormat::SystemEndian.decode(UInt32, handshake).should eq(GPM::MAGIC)
        decode_config(handshake[4, 16]).should eq(gpm.config)
        gpm.stop
      end
    end
  end

  describe "#config=" do
    it "resends the new config to GPM" do
      with_server do |server, path|
        gpm = GPM.new(file: path)
        peer, _ = accept_handshake(server)
        gpm.config = gpm.config.copy_with(event_mask: GPM::Types::MOVE, vc: 5)
        resent = Bytes.new 16
        peer.read_fully resent
        decode_config(resent).should eq(gpm.config)
        gpm.stop
      end
    end
  end

  describe "#get_event" do
    it "decodes a Gpm_Event struct" do
      with_server do |server, path|
        gpm = GPM.new(file: path)
        peer, _ = accept_handshake(server)
        expected = GPM::Event.new(
          GPM::Buttons::LEFT | GPM::Buttons::RIGHT, GPM::Modifiers::CONTROL,
          6_u16, -1_i16, 2_i16, 163_i16, 35_i16,
          GPM::Types::DRAG | GPM::Types::SINGLE | GPM::Types::MOTION,
          2, GPM::Margins::TOP | GPM::Margins::LEFT, 0_i16, -3_i16
        )
        peer.write encode(expected)
        gpm.get_event.should eq(expected)
        gpm.stop
      end
    end

    it "consumes and checks the magic word before each event when use_magic is set" do
      with_server do |server, path|
        gpm = GPM.new(file: path, use_magic: true)
        peer, _ = accept_handshake(server, 20)
        expected = event(GPM::Buttons::LEFT, GPM::Types::DOWN)
        peer.write_bytes GPM::MAGIC, GPM::ENDIAN
        peer.write encode(expected)
        gpm.get_event.should eq(expected)

        peer.write_bytes 0xdeadbeef_u32, GPM::ENDIAN
        peer.write encode(expected)
        expect_raises(IO::Error, /magic/) { gpm.get_event }
        gpm.stop
      end
    end

    it "returns nil once the daemon closes the connection" do
      with_server do |server, path|
        gpm = GPM.new(file: path)
        peer, _ = accept_handshake(server)
        peer.close
        gpm.get_event.should be_nil
        gpm.stop
      end
    end

    # After `stop` closes our socket, `get_event` must honour its documented
    # "returns nil once the connection is closed" contract rather than raise,
    # so a `while e = gpm.get_event` loop ends cleanly on shutdown.
    it "returns nil after the connection is stopped instead of raising" do
      with_server do |_, path|
        gpm = GPM.new(file: path)
        gpm.stop
        gpm.get_event.should be_nil
      end
    end
  end

  describe "#request" do
    it "sends a pid-0 config carrying the request id and returns the reply event" do
      with_server do |server, path|
        gpm = GPM.new(file: path)
        peer, _ = accept_handshake(server)
        reply = event(GPM::Buttons::None, GPM::Types.new(3))
        sent = Bytes.new 16
        done = Channel(Nil).new
        spawn do
          peer.read_fully sent
          peer.write encode(reply)
          done.send nil
        end
        gpm.request(GPM::Request::SNAPSHOT).should eq(reply)
        done.receive
        request = decode_config(sent)
        request.pid.should eq(0)
        request.vc.should eq(GPM::Request::SNAPSHOT.value)
        request.event_mask.should eq(gpm.config.event_mask)
        gpm.stop
      end
    end

    it "does not wait for a reply to requests GPM never answers" do
      with_server do |server, path|
        gpm = GPM.new(file: path)
        peer, _ = accept_handshake(server)
        gpm.request(GPM::Request::NOPASTE).should be_nil
        sent = Bytes.new 16
        peer.read_fully sent
        decode_config(sent).vc.should eq(GPM::Request::NOPASTE.value)
        gpm.stop
      end
    end
  end

  describe "#stop" do
    it "is idempotent" do
      with_server do |_, path|
        gpm = GPM.new(file: path)
        gpm.stop
        gpm.stop
        gpm.socket.closed?.should be_true
      end
    end
  end

  describe GPM::Config do
    # Constructing a Config must not raise when no stdio fd is backed by a
    # /proc console entry (redirected stdio, non-Linux, etc.): the `vc`
    # default has to fall back to 0 rather than abort construction.
    it "constructs without raising when the console can't be detected" do
      GPM::Config.new.vc.should be_a(Int32)
    end

    it "honors an explicitly provided vc without consulting the tty" do
      GPM::Config.new(vc: 7).vc.should eq(7)
    end
  end

  describe GPM::Types do
    it "extracts the bare event bits" do
      (GPM::Types::DOWN | GPM::Types::SINGLE | GPM::Types::MOTION).bare_events.should eq(GPM::Types::DOWN)
      (GPM::Types::ENTER | GPM::Types::HARD).bare_events.should eq(GPM::Types::ENTER)
    end
  end

  describe "Event uniform accessors" do
    it "classifies a left button press" do
      e = event(GPM::Buttons::LEFT, GPM::Types::DOWN | GPM::Types::SINGLE, GPM::Modifiers::SHIFT)
      e.left?.should be_true
      e.middle?.should be_false
      e.right?.should be_false
      e.pressed?.should be_true
      e.released?.should be_false
      e.moved?.should be_false
      e.wheel?.should be_false
      e.shift?.should be_true
      e.ctrl?.should be_false
    end

    it "classifies a release" do
      e = event(GPM::Buttons::LEFT, GPM::Types::UP)
      e.released?.should be_true
      e.pressed?.should be_false
    end

    it "classifies wheel up/down" do
      up = event(GPM::Buttons::UP, GPM::Types::DOWN)
      up.wheel_up?.should be_true
      up.wheel?.should be_true
      down = event(GPM::Buttons::DOWN, GPM::Types::DOWN)
      down.wheel_down?.should be_true
    end

    it "classifies motion and drag" do
      event(GPM::Buttons::None, GPM::Types::MOVE).moved?.should be_true
      event(GPM::Buttons::LEFT, GPM::Types::DRAG).moved?.should be_true
    end
  end
end
