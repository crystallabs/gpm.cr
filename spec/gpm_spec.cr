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

describe GPM do
  it "works" do
    true.should eq(true)
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
