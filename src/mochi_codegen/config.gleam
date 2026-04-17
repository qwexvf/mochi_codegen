// mochi_codegen/config.gleam
// Project configuration for mochi code generation
//
// Config file: mochi.config.json

import gleam/dynamic/decode
import gleam/json
import gleam/option.{type Option, None, Some}
import simplifile

/// Default config file name
pub const config_file = "mochi.config.json"

/// Project configuration
pub type Config {
  Config(
    /// Path to the GraphQL schema file(s)
    schema: String,
    /// Output file paths
    output: OutputConfig,
    /// Gleam codegen options
    gleam: GleamConfig,
  )
}

/// Output file path configuration
pub type OutputConfig {
  OutputConfig(
    /// TypeScript type definitions output path
    typescript: Option(String),
    /// Gleam types output path
    gleam_types: Option(String),
    /// Gleam resolver stubs output path
    resolvers: Option(String),
    /// Normalized SDL output path
    sdl: Option(String),
  )
}

/// Gleam code generation options
pub type GleamConfig {
  GleamConfig(
    /// Module name for generated types
    types_module: String,
    /// Module name for generated resolvers
    resolvers_module: String,
    /// Whether to generate doc comments
    generate_docs: Bool,
  )
}

/// Create a default config
pub fn default() -> Config {
  Config(
    schema: "schema.graphql",
    output: OutputConfig(
      typescript: Some("src/generated/types.ts"),
      gleam_types: Some("src/generated/schema_types.gleam"),
      resolvers: Some("src/generated/resolvers.gleam"),
      sdl: None,
    ),
    gleam: GleamConfig(
      types_module: "schema_types",
      resolvers_module: "resolvers",
      generate_docs: True,
    ),
  )
}

/// Encode config to JSON string
pub fn to_json(config: Config) -> String {
  json.object([
    #("schema", json.string(config.schema)),
    #("output", encode_output(config.output)),
    #("gleam", encode_gleam(config.gleam)),
  ])
  |> json.to_string
}

fn encode_output(output: OutputConfig) -> json.Json {
  json.object(
    []
    |> prepend_optional("sdl", output.sdl)
    |> prepend_optional("resolvers", output.resolvers)
    |> prepend_optional("gleam_types", output.gleam_types)
    |> prepend_optional("typescript", output.typescript),
  )
}

fn prepend_optional(
  entries: List(#(String, json.Json)),
  key: String,
  value: Option(String),
) -> List(#(String, json.Json)) {
  case value {
    Some(v) -> [#(key, json.string(v)), ..entries]
    None -> entries
  }
}

fn encode_gleam(gleam: GleamConfig) -> json.Json {
  json.object([
    #("types_module", json.string(gleam.types_module)),
    #("resolvers_module", json.string(gleam.resolvers_module)),
    #("generate_docs", json.bool(gleam.generate_docs)),
  ])
}

/// Decode config from JSON string
pub fn from_json(input: String) -> Result(Config, String) {
  case json.parse(input, config_decoder()) {
    Ok(config) -> Ok(config)
    Error(_) -> Error("Failed to parse mochi.config.json")
  }
}

fn config_decoder() -> decode.Decoder(Config) {
  use schema <- decode.field("schema", decode.string)
  use output <- decode.field("output", output_decoder())
  use gleam <- decode.field("gleam", gleam_decoder())
  decode.success(Config(schema:, output:, gleam:))
}

fn output_decoder() -> decode.Decoder(OutputConfig) {
  use typescript <- decode.optional_field(
    "typescript",
    None,
    decode.optional(decode.string),
  )
  use gleam_types <- decode.optional_field(
    "gleam_types",
    None,
    decode.optional(decode.string),
  )
  use resolvers <- decode.optional_field(
    "resolvers",
    None,
    decode.optional(decode.string),
  )
  use sdl <- decode.optional_field("sdl", None, decode.optional(decode.string))
  decode.success(OutputConfig(typescript:, gleam_types:, resolvers:, sdl:))
}

fn gleam_decoder() -> decode.Decoder(GleamConfig) {
  use types_module <- decode.optional_field(
    "types_module",
    "schema_types",
    decode.string,
  )
  use resolvers_module <- decode.optional_field(
    "resolvers_module",
    "resolvers",
    decode.string,
  )
  use generate_docs <- decode.optional_field("generate_docs", True, decode.bool)
  decode.success(GleamConfig(types_module:, resolvers_module:, generate_docs:))
}

/// Read config from the default config file
pub fn read() -> Result(Config, String) {
  read_from(config_file)
}

/// Read config from a specific path
pub fn read_from(path: String) -> Result(Config, String) {
  case simplifile.read(path) {
    Ok(content) -> from_json(content)
    Error(_) ->
      Error(
        "Could not read "
        <> path
        <> ". Run `gleam run -m mochi_codegen/cli -- init` to create one.",
      )
  }
}

/// Write config to the default config file
pub fn write(config: Config) -> Result(Nil, String) {
  write_to(config, config_file)
}

/// Write config to a specific path
pub fn write_to(config: Config, path: String) -> Result(Nil, String) {
  case simplifile.write(path, to_json(config) <> "\n") {
    Ok(_) -> Ok(Nil)
    Error(_) -> Error("Could not write " <> path)
  }
}

/// Check if a config file exists
pub fn exists() -> Bool {
  case simplifile.is_file(config_file) {
    Ok(True) -> True
    _ -> False
  }
}
