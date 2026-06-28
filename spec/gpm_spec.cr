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
  it "works" do
    true.should eq(true)
  end

  describe "#initialize" do
    # Daemon-free: a throwaway UNIXServer makes the connect succeed, then the
    # handshake is forced to raise. The just-opened socket must be closed (not
    # leaked) before the exception escapes the constructor.
    it "closes the opened socket if the initial handshake fails" do
      path = File.tempname("gpm-spec", ".sock")
      server = UNIXServer.new(path)
      begin
        FailingGPM.captured = nil
        expect_raises(Exception, "forced handshake failure") do
          FailingGPM.new(file: path)
        end
        FailingGPM.captured.not_nil!.closed?.should be_true
      ensure
        server.close
        File.delete(path) if File.exists?(path)
      end
    end
  end

  describe "#get_event" do
    # Daemon-free: a throwaway UNIXServer lets the constructor's handshake
    # write succeed. After `stop` closes our socket, `get_event` must honour
    # its documented "returns nil once the connection is closed" contract and
    # return nil rather than raising IO::Error, so callers' shutdown of a
    # `while e = gpm.get_event` loop ends cleanly instead of crashing.
    it "returns nil after the connection is stopped instead of raising" do
      path = File.tempname("gpm-spec", ".sock")
      server = UNIXServer.new(path)
      begin
        gpm = GPM.new(file: path)
        gpm.stop
        gpm.get_event.should be_nil
      ensure
        server.close
        File.delete(path) if File.exists?(path)
      end
    end
  end

  describe "#stop" do
    # Daemon-free: stop must stay idempotent now that the redundant
    # `unless @socket.closed?` guard is gone (UNIXSocket#close is idempotent),
    # so calling it twice must not raise.
    it "is idempotent" do
      path = File.tempname("gpm-spec", ".sock")
      server = UNIXServer.new(path)
      begin
        gpm = GPM.new(file: path)
        gpm.stop
        gpm.stop
        gpm.socket.closed?.should be_true
      ensure
        server.close
        File.delete(path) if File.exists?(path)
      end
    end
  end

  describe GPM::Config do
    # Constructing a Config must not raise when stdin isn't backed by a /proc
    # tty entry (redirected stdin, non-Linux, etc.): the `vc` default has to fall
    # back to a plain Int32 rather than letting File.readlink's exception abort
    # construction. (Pre-fix this raised File::NotFoundError.)
    it "constructs without raising when the controlling tty can't be detected" do
      GPM::Config.new.vc.should be_a(Int32)
    end

    it "honors an explicitly provided vc without consulting the tty" do
      GPM::Config.new(vc: 7).vc.should eq(7)
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
