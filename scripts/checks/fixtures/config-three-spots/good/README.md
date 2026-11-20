# Good (fixture)

A miniature `config.lua` whose two structures agree: `pi.Options` has three
fields and `defaults` has three keys, `pi.VisionConfig` is reached by descent
through `vision` and agrees in both directions, and positional values nowhere
become keys.

Two asymmetries are deliberate and must stay quiet:

* `pi.Options.status_message?` is optional and has no default, and
* `pi.VisionConfig.model?` is optional and has no default.

An optional field is documented as "may be unset", so `defaults` legitimately
omits it — a rule that fires here would fire 15 times on the real tree.
