# mochi_codegen

Code generation (TypeScript types, GraphQL SDL, Gleam types) and CLI for mochi GraphQL.

## Installation

```sh
gleam add mochi_codegen
```

## CLI

```sh
gleam run -m mochi_codegen/cli -- init       # create mochi.config.json
gleam run -m mochi_codegen/cli -- generate   # generate from config
```

## Programmatic Usage

```gleam
import mochi_codegen

let ts  = mochi_codegen.to_typescript(schema)
let sdl = mochi_codegen.to_sdl(schema)
let html = mochi_codegen.graphiql("/graphql")
```

## Config (`mochi.config.json`)

```json
{
  "schema": "schema.graphql",
  "output": {
    "typescript": "src/generated/types.ts",
    "sdl": null
  }
}
```

## License

Apache-2.0

