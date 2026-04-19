> **Active development** — breaking changes may be pushed to `main` at any time.


# mochi_codegen

Code generation (TypeScript types, GraphQL SDL, Gleam types + resolver stubs) and CLI for mochi GraphQL.

## Installation

```toml
# gleam.toml
[dependencies]
mochi_codegen = { git = "https://github.com/qwexvf/mochi_codegen", ref = "main" }
```

## CLI

```sh
gleam run -m mochi_codegen/cli -- init       # create mochi.config.yaml
gleam run -m mochi_codegen/cli -- generate   # generate from config
```

## Config (`mochi.config.yaml`)

```yaml
schema: "graphql/*.graphql"

# Optional: generate resolver boilerplate from .gql client operation files
operations_input: "src/graphql/**/*.gql"

output:
  typescript: "src/generated/types.ts"   # TypeScript type definitions
  gleam_types: "src/api/domain/"         # Gleam domain types (dir = one file per schema)
  resolvers: "src/api/schema/"           # Gleam resolver stubs (preserved on regen)
  operations: "src/api/schema/"          # Gleam operation resolvers (from .gql files)
  sdl: null                              # Normalised SDL (omit to skip)

gleam:
  types_module_prefix: "api/domain"
  resolvers_module_prefix: "api/schema"
  type_suffix: "_types"
  resolver_suffix: "_resolvers"
  generate_docs: true
```

Output paths ending in `/` produce one file per schema file. Paths without `/` merge all schemas into a single file.

### Write policies

| Output | Policy |
|--------|--------|
| `typescript`, `sdl` | Always overwrite |
| `gleam_types` | Overwrite only when content changed |
| `resolvers`, `operations` | Never overwrite existing functions — only appends new stubs |

## Programmatic Usage

```gleam
import mochi_codegen

let ts   = mochi_codegen.to_typescript(schema)
let sdl  = mochi_codegen.to_sdl(schema)
let html = mochi_codegen.graphiql("/graphql")
```

## License

Apache-2.0

---
Built with the help of [Claude Code](https://claude.ai/code).
