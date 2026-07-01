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
    ALTGR   = 2
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
  end

  record Config,
    event_mask : Types = Types::All, # 2047 (all defined Types bits)
    default_mask : Types = (Types::MOVE | Types::HARD),
    min_mod : UInt16 = 0,
    max_mod : UInt16 = 0xffff,
    pid : Int32 = Process.pid.to_i32,
    # TODO: for vc: should also check for /dev/input/ (if tty not found? And anyway, how?)
    #
    # `rescue nil` makes the `|| 0` fallback reachable: `File.readlink` raises
    # whenever stdin isn't backed by a `/proc` tty entry (redirected/piped stdin,
    # service manager, non-Linux), and `record` evaluates this default eagerly on
    # every `Config.new` even when `vc:` is passed explicitly.
    vc : Int32 = (File.readlink("/proc/#{Process.pid}/fd/0").match(/tty(\d+)/).try(&.[1].to_i) rescue nil) || 0

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
    # wdx/y: wheel displacement for this event. No absolute value needed since
    # wheel movement is used for scrolling, not cursor positioning. A single
    # mouse uses wdy ("vertical scroll" wheel).
    wdx : Int16,
    wdy : Int16 do
    # Uniform accessors for common mouse-event queries, instead of unpacking
    # the raw `Buttons`/`Modifiers`/`Types` flag words directly.

    # Modifier keys held during the event.
    def shift? : Bool
      modifiers.shift?
    end

    def ctrl? : Bool
      modifiers.control?
    end

    def meta? : Bool
      modifiers.meta?
    end

    # Which physical button the event pertains to.
    def left? : Bool
      buttons.left?
    end

    def middle? : Bool
      buttons.middle?
    end

    def right? : Bool
      buttons.right?
    end

    # Scroll-wheel motion (GPM reports it through the `UP`/`DOWN` button bits).
    def wheel_up? : Bool
      buttons.up?
    end

    def wheel_down? : Bool
      buttons.down?
    end

    def wheel? : Bool
      wheel_up? || wheel_down?
    end

    # Action classification, derived from the `Types` flags.
    def pressed? : Bool
      types.down?
    end

    def released? : Bool
      types.up?
    end

    # Pointer motion (a bare move, or a drag with a button held).
    def moved? : Bool
      types.move? || types.drag?
    end
  end

  property file : String
  property socket : UNIXSocket
  property? use_magic : Bool
  property config : Config
  property magic : UInt32

  def initialize(@file = SOCKET, @use_magic = USE_MAGIC, @magic = MAGIC)
    @config = Config.new
    @socket = UNIXSocket.new @file

    # If the handshake fails, the exception would propagate before the socket
    # is ever handed back, leaking the descriptor until GC finalizes it. Close
    # explicitly on the error path instead.
    begin
      send_config
    rescue ex
      @socket.close
      raise ex
    end

    # Requests to GPM (not just receiving events) are issued the same way:
    # write the config struct with pid=0 and vc=REQUEST_ID; result comes back
    # as an event.
  end

  def send_config(config = @config, socket = @socket)
    # Assemble the whole Gpm_Connect struct in memory and write it in one call.
    buffer = IO::Memory.new @use_magic ? 20 : 16

    buffer.write_bytes @magic, ENDIAN if @use_magic

    # Trailing numbers are each field's cumulative byte END-offset in the
    # default (no-magic) layout. A leading 4-byte magic prefix shifts all by +4.
    buffer.write_bytes config.event_mask.value.to_u16, ENDIAN   # u16 -> ends @ 2
    buffer.write_bytes config.default_mask.value.to_u16, ENDIAN # u16 -> ends @ 4
    buffer.write_bytes config.min_mod, ENDIAN                   # u16 -> ends @ 6
    buffer.write_bytes config.max_mod, ENDIAN                   # u16 -> ends @ 8
    buffer.write_bytes config.pid, ENDIAN                       # i32 -> ends @ 12
    buffer.write_bytes config.vc, ENDIAN                        # i32 -> ends @ 16

    socket.write buffer.to_slice
  end

  # Reads a naturally-aligned field of `type` out of `ptr` at `offset`. GPM
  # writes its `Gpm_Event` C struct host-native and aligned from offset 0, so
  # a typed-pointer read reproduces it on any platform while skipping the
  # bounds-checked sub-slicing a `bytes[off, n]` decode would incur.
  private macro read_field(ptr, offset, type)
    ({{ptr}} + {{offset}}).as({{type}}*).value
  end

  # Reads one event from the socket. Returns `nil` once the connection is
  # closed (e.g. GPM exits), so callers can use `while e = gpm.get_event`.
  #
  # Pulls the whole 28-byte Gpm_Event struct with one `read_fully` and decodes
  # fields from that stack buffer, instead of a buffered read per field.
  def get_event(raw = @socket)
    # Int32[7] (28 bytes) forces 4-byte alignment so every multi-byte field
    # below is aligned. ENDIAN is SystemEndian, matching how GPM writes the
    # struct, so each typed-pointer read is equivalent to `ENDIAN.decode`.
    storage = uninitialized Int32[7]
    ptr = storage.to_unsafe.as(UInt8*)
    raw.read_fully(Slice.new(ptr, 28))

    Event.new(
      Buttons.new(ptr[0]),        # raw[0]
      Modifiers.new(ptr[1]),      # raw[1]
      read_field(ptr, 2, UInt16), # vc
      read_field(ptr, 4, Int16),  # dx
      read_field(ptr, 6, Int16),  # dy
      read_field(ptr, 8, Int16),  # x
      read_field(ptr, 10, Int16), # y
      Types.new(read_field(ptr, 12, Int32)),
      read_field(ptr, 16, Int32), # nr. of clicks
      Margins.new(read_field(ptr, 20, Int32)),
      read_field(ptr, 24, Int16), # wdx
      read_field(ptr, 26, Int16), # wdy
    )
  rescue IO::EOFError
    # GPM exited / closed its end: clean stream end, signalled as nil.
    nil
  rescue ex : IO::Error
    # Our own socket closed (e.g. via `stop` from another fiber while this
    # read was blocked) counts as "connection closed" too. Other I/O errors
    # are genuine failures and must still propagate.
    raise ex unless raw.closed?
    nil
  end

  def stop
    # Idempotent: calling stop twice is harmless.
    @socket.close
  end
end
