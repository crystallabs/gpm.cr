require "socket"

class GPM
  VERSION = "1.0.5"

  USE_MAGIC = false
  MAGIC     = 0x47706D4Cu32
  SOCKET    = "/dev/gpmctl"

  # GPM writes its raw C structs onto the socket, so all multi-byte fields
  # are in the host's native byte order (little-endian on x86/most ARM).
  ENDIAN = IO::ByteFormat::SystemEndian

  @[Flags]
  enum Buttons
    RIGHT  =  1
    MIDDLE =  2
    LEFT   =  4
    FOURTH =  8
    UP     = 16
    DOWN   = 32
  end

  @[Flags]
  enum Modifiers
    SHIFT   = 1
    CONTROL = 4
    META    = 8
  end

  enum Request
    SNAPSHOT = 0
    BUTTONS  = 1
    CONFIG   = 2
    NOPASTE  = 3
  end

  @[Flags]
  enum Margins
    TOP    = 1
    BOTTOM = 2
    LEFT   = 4
    RIGHT  = 8
  end

  @[Flags]
  enum Types
    MOVE = 1
    DRAG = 2 # exactly one of the bare ones is active at a time */
    DOWN = 4
    UP   = 8

    SINGLE = 16 # at most one in three is set */
    DOUBLE = 32
    TRIPLE = 64 # WARNING: I depend on the values */

    MOTION = 128 # motion during click? */
    HARD   = 256 # if set in the defaultMask, force an already used event to pass over to another handler */

    ENTER =  512 # enter event, user in Roi's */
    LEAVE = 1024 # leave event, used in Roi's */

    def bare_events
      self & (Types.new(0x0f) | ENTER | LEAVE)
    end

    def strict_single?
      single? && !motion?
    end

    def any_single?
      single?
    end

    def strict_double?
      double? && !motion?
    end

    def any_double?
      double?
    end

    def strict_triple?
      triple? && !motion?
    end

    def any_triple?
      triple?
    end

    def to_io(io, format)
      io.write_bytes value, format
    end
  end

  record Config,
    event_mask : Types = Types::All, # 2047 (all defined Types bits)
    default_mask : Types = (Types::MOVE | Types::HARD),
    min_mod : UInt16 = 0,
    max_mod : UInt16 = 0xffff,
    pid : Int32 = Process.pid.to_i32,
    # TODO: for vc: should  also check for /dev/input/ (if tty not found? And anyway, how?)
    vc : Int32 = File.readlink("/proc/#{Process.pid}/fd/0").match(/tty(\d+)/).try(&.[1].to_i) || 0

  record Event,
    buttons : Buttons,
    modifiers : Modifiers, # try to be a multiple of 4
    vc : UInt16,           # virtual console
    dx : Int16,            # displacement x
    dy : Int16,            # displacement y for this event, and absolute x,y
    x : Int16,             # absolute x
    y : Int16,             # absolute y
    types : Types,
    clicks : Int32, # number of clicks, e.g. double click are determined by time-based processing
    margins : Margins,
    # wdx/y: displacement of wheels in this event. Absolute values are not
    # required, because wheel movement is typically used for scrolling
    # or selecting fields, not for cursor positioning. The application
    # can determine when the end of file or form is reached, and not
    # go any further. A single mouse will use wdy, "vertical scroll" wheel.
    wdx : Int16,
    wdy : Int16

  property file : String
  property socket : UNIXSocket
  property use_magic : Bool
  property config : Config
  property magic : UInt32

  def initialize(@file = SOCKET, @use_magic = USE_MAGIC, @magic = MAGIC)
    @config = Config.new
    @socket = UNIXSocket.new @file
    send_config

    # In addition to receiving events from GPM, it is also possible to issue requests
    # to GPM. This is done by writing the config structure into the socket, but
    # with pid=0 and vc=REQUEST_ID. The result is returned as an event as usual.
    #
    # @config = @config.copy_with pid: 0i32, vc: Request::NOPASTE
    # send_config
  end

  def send_config(config = @config, socket = @socket)
    # Assemble the whole Gpm_Connect struct in memory and write it in one
    # call, so the request reaches GPM as a single contiguous send.
    buffer = IO::Memory.new @use_magic ? 20 : 16

    buffer.write_bytes @magic, ENDIAN if @use_magic

    buffer.write_bytes config.event_mask.value.to_u16, ENDIAN   # 4 ;
    buffer.write_bytes config.default_mask.value.to_u16, ENDIAN # 6 ;
    buffer.write_bytes config.min_mod, ENDIAN                   # 8 ;
    buffer.write_bytes config.max_mod, ENDIAN                   # 10 ;
    buffer.write_bytes config.pid, ENDIAN                       # 12 ;
    buffer.write_bytes config.vc, ENDIAN                        # 16 ;

    socket.write buffer.to_slice
  end

  # Reads one event from the socket. Returns `nil` once the connection is
  # closed (e.g. GPM exits), so callers can use `while e = gpm.get_event`.
  def get_event(raw = @socket)
    Event.new(
      Buttons.new(raw.read_bytes(UInt8, ENDIAN)),   # raw[0]
      Modifiers.new(raw.read_bytes(UInt8, ENDIAN)), # raw[1]
      raw.read_bytes(UInt16, ENDIAN),               # vc
      raw.read_bytes(Int16, ENDIAN),                # dx
      raw.read_bytes(Int16, ENDIAN),                # dy
      raw.read_bytes(Int16, ENDIAN),                # x
      raw.read_bytes(Int16, ENDIAN),                # y
      Types.new(raw.read_bytes(Int32, ENDIAN)),
      raw.read_bytes(Int32, ENDIAN), # nr. of clicks
      Margins.new(raw.read_bytes(Int32, ENDIAN)),
      raw.read_bytes(Int16, ENDIAN), # wdx
      raw.read_bytes(Int16, ENDIAN), # wdy
    )
  rescue IO::EOFError
    nil
  end

  def stop
    @socket.close unless @socket.closed?
  end
end
