//// Code generation tools for mochi GraphQL.
////
//// Generates TypeScript types, GraphQL SDL, and serves the GraphiQL playground.
////
//// ## Usage
////
//// ```gleam
//// import mochi_codegen
////
//// // Generate GraphQL SDL from your schema
//// let sdl = mochi_codegen.to_sdl(schema)
////
//// // Generate TypeScript type definitions
//// let ts = mochi_codegen.to_typescript(schema)
////
//// // Serve GraphiQL in your HTTP handler
//// let html = mochi_codegen.graphiql("/graphql")
//// ```

import mochi/schema.{type Schema}
import mochi_codegen/playground
import mochi_codegen/sdl
import mochi_codegen/typescript

pub fn to_sdl(schema: Schema) -> String {
  sdl.generate(schema)
}

pub fn to_typescript(schema: Schema) -> String {
  typescript.generate(schema)
}

pub fn graphiql(endpoint: String) -> String {
  playground.graphiql(endpoint)
}

pub fn apollo_sandbox(endpoint: String) -> String {
  playground.apollo_sandbox(endpoint)
}
