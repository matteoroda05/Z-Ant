# `src/codegen/IR_zant/op_union/operators/op_qlinearconv/cmsis_parameters.zig`

## Role

`cmsis_parameters.zig` is QLinearConv's adapter to the generic CMSIS parameter
capability layer. It keeps QLinearConv preparation policy inside the operator
folder while leaving formatting, deduplication, and initializer-use analysis in
`IR_zant/cmsis/parameter_codegen.zig`.

The corresponding optional methods on `QLinearConv` are intentionally short and
delegate directly to this adapter.

## Replaced initializers

`collectReplacedInitializers(...)` first checks the shared QLinearConv
classifier. For a supported standard or depthwise node it marks:

- the original weight initializer;
- the bias initializer, when a named bias is present.

Scales and zero-points are retained because the generated runtime path still
uses activation zero-points and because only explicitly replaced initializers
may be omitted. The generic collector protects a marked initializer whenever
any other graph use is not replaced.

## Prepared output

`writePreparedParameters(...)` calls `qlinearconv_prepare(...)`, then emits five
constants through the generic emitter:

| Semantic role | Symbol |
|---|---|
| signed filter | `cmsis_<output>_filter` |
| filter shape | `cmsis_<output>_filter_shape` |
| `i32` bias | `cmsis_<output>_bias` |
| requant multiplier | `cmsis_<output>_multiplier` |
| requant shift | `cmsis_<output>_shift` |

`<output>` is the sanitized output tensor name. Using one output-keyed namespace
for every semantic role prevents incompatible prepared representations from
being deduplicated merely because two nodes share a source initializer.

The adapter does not branch on standard versus depthwise. That distinction is
owned by `qlinearconv_prepare(...)`, which returns the appropriate filter layout
and channel multiplier metadata.

## Extension boundary

Future grouped QLinearConv support should add a local `.grouped` preparation
case and runtime behavior. It should not require a new branch in this adapter,
the generic parameter layer, or `parameters.zig` as long as it emits the same
semantic prepared roles.
