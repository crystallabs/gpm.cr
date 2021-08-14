[![Linux CI](https://github.com/crystallabs/gpm.cr/workflows/Linux%20CI/badge.svg)](https://github.com/crystallabs/gpm.cr/actions?query=workflow%3A%22Linux+CI%22+event%3Apush+branch%3Amaster)
[![Version](https://img.shields.io/github/tag/crystallabs/gpm.cr.svg?maxAge=360)](https://github.com/crystallabs/gpm.cr/releases/latest)
[![License](https://img.shields.io/github/license/crystallabs/gpm.cr.svg)](https://github.com/crystallabs/gpm.cr/blob/master/LICENSE)

# GPM

Crystal-native client for GPM (console mouse).

NOTE: This library will only work when a program is running in the console and GPM server is running. It won't work under X.

## Installation

1. Add the dependency to your `shard.yml`:

   ```yaml
   dependencies:
     gpm:
       github: crystallabs/gpm.cr
       version: ~> 1.0
   ```

2. Run `shards install`

## Usage

```crystal
require "gpm"

gpm = GPM.new
while e = gpm.get_event
  p e
end
```

Example output:

```
$ crystal examples/gpm.cr

GPM::Event(@buttons=None, @modifiers=None, @vc=6, @dx=0, @dy=0, @x=163, @y=35, @type=MOVE, @clicks=0, @margin=None, @wdx=0, @wdy=0)
GPM::Event(@buttons=LEFT, @modifiers=None, @vc=6, @dx=0, @dy=0, @x=163, @y=35, @type=DOWN | SINGLE, @clicks=0, @margin=None, @wdx=0, @wdy=0)
GPM::Event(@buttons=LEFT, @modifiers=None, @vc=6, @dx=0, @dy=0, @x=163, @y=35, @type=UP | SINGLE, @clicks=0, @margin=None, @wdx=0, @wdy=0)
GPM::Event(@buttons=RIGHT, @modifiers=None, @vc=6, @dx=0, @dy=0, @x=163, @y=35, @type=DOWN | SINGLE, @clicks=0, @margin=None, @wdx=0, @wdy=0)
GPM::Event(@buttons=RIGHT, @modifiers=CTRL, @vc=6, @dx=0, @dy=0, @x=163, @y=35, @type=DRAG | SINGLE | MOTION, @clicks=0, @margin=None, @wdx=0, @wdy=0)
GPM::Event(@buttons=RIGHT, @modifiers=CTRL, @vc=6, @dx=1, @dy=0, @x=164, @y=35, @type=DRAG | SINGLE | MOTION, @clicks=0, @margin=None, @wdx=0, @wdy=0)
GPM::Event(@buttons=RIGHT, @modifiers=CTRL, @vc=6, @dx=0, @dy=0, @x=164, @y=35, @type=UP | SINGLE | MOTION, @clicks=0, @margin=None, @wdx=0, @wdy=0)
```

## Thanks

* All the fine folks on Libera.Chat IRC channel #crystal-lang and on Crystal's Gitter channel https://gitter.im/crystal-lang/crystal

## Licensing

For licensing to use in your next project, consider Coherent or Post-Open Source licenses:

* https://licenseuse.org/
* https://www.youtube.com/watch?v=vTsc1m78BUk
* https://www.youtube.com/watch?v=XRl-it1-ruI
* https://perens.com/2020/10/06/post-open-source-license-early-draft/