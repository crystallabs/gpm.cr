require "../src/gpm"

gpm = GPM.new
while e = gpm.get_event
  p e
end

