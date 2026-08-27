# `src/codegen/IR_zant/cmsis/parameter_codegen.zig`

## Role

`parameter_codegen.zig` is the operator-independent CMSIS parameter-generation
layer. It lets an operator opt into prepared CMSIS constants through optional
methods discovered at compile time, without adding an operator or CMSIS-kind
branch to `parameters.zig`.

The layer follows `Op_union`'s existing `inline else` dispatch style. For each
union payload it checks for these declarations with `@hasDecl`:

```zig
cmsis_is_supported(self) bool
cmsis_collect_replaced_initializers(self, collector) !void
cmsis_write_prepared_parameters(self, emitter) !void
```

An operator that declares no hooks is skipped automatically. Adding another
CMSIS-backed operator therefore requires only local hooks and an operator-owned
adapter.

## Capability dispatch

`isSupported(node)` switches over `node.op` with `inline else`. When the active
payload exposes `cmsis_is_supported`, that method owns the eligibility decision;
otherwise the result is `false`.

The two private dispatch helpers use the same pattern for initializer collection
and prepared-parameter emission. The generic layer never imports or switches on
QLinearConv.

## Safe initializer exclusion

`collectExcludedInitializers(...)` builds two sets:

- **candidates:** initializers that a supported node says its prepared constants
  replace;
- **protected:** every input use not replaced by that particular node.

An initializer enters the final exclusion set only when it is a candidate and
is never protected. This matters when an initializer is shared: if one node uses
a prepared representation but another node still needs the original tensor, the
original remains in `static_parameters.zig`.

The decision is per use, not merely per tensor name or operator kind. This also
allows future operators to replace different semantic subsets of their inputs.

## `ParameterEmitter`

`ParameterEmitter` owns the output-formatting policy shared by operator adapters:

- `emitShape4(...)` emits a `[4]usize` shape constant;
- `emitArray(...)` emits a typed array in the configured link section;
- an owned symbol map deduplicates exact symbols safely;
- `deinit()` releases the emitter-owned symbol keys.

Operators supply semantic data and symbol names; they do not duplicate array
formatting or flash-section syntax.

QLinearConv uses output-keyed names, so two nodes that share one source filter
can still emit different prepared filters without an accidental name collision.

## Consumers

- `mod_cmsis.zig` delegates `isCmsisSupported(...)` to this module.
- `parameters.zig` calls `collectExcludedInitializers(...)` before normal
  initializer output and `emitPreparedParameters(...)` afterward.
- `op_qlinearconv.zig` exposes the optional hooks.
- `op_qlinearconv/cmsis_parameters.zig` implements QLinearConv's adapter.

## Tests

Unit tests in this file cover optional-hook discovery, unsupported-operator
skipping, protection of a shared initializer with an unreplaced use, exact
symbol deduplication, and isolation of two output-keyed symbols.
