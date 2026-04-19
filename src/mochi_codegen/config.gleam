// mochi_codegen/config.gleam
// Project configuration for mochi code generation
//
// Config file: mochi.config.yaml
//
// Example:
//
//   schema: "graphql/*.graphql"
//
//   output:
//     gleam_types: "src/api/domain/"
//     resolvers: "src/api/schema/"
//     typescript: "apps/web/src/generated/types.ts"
//
//   gleam:
//     types_module_prefix: "api/domain"
//     resolvers_module_prefix: "api/schema"
//     type_suffix: "_types"
//     resolver_suffix: "_resolvers"
//     generate_docs: true
//
// Output paths:
//   - Ending in "/" → directory mode: one file generated per source schema file.
//   - Otherwise     → single file: all schema files merged into one output.
//
// Schema:
//   Accepts a glob string ("graphql/*.graphql"), a single path, or a YAML list
//   of globs/paths. Globs are expanded at generation time.

import gleam/option.{type Option, None, Some}
import gleam/string
import simplifile
import taffy

/// Default config file name
pub const config_file = "mochi.config.yaml"

/// Project configuration
pub type Config {
  Config(
    /// Glob pattern(s) or explicit path(s) to GraphQL schema files.
    schema: List(String),
    /// Glob pattern(s) for GraphQL operation files (.gql) to generate resolvers from.
    operations_input: Option(String),
    /// Output configuration
    output: OutputConfig,
    /// Gleam-specific codegen options
    gleam: GleamConfig,
  )
}

/// Output paths. A path ending in "/" generates one file per schema file.
pub type OutputConfig {
  OutputConfig(
    /// TypeScript type definitions (file or directory)
    typescript: Option(String),
    /// Gleam domain types (file or directory)
    gleam_types: Option(String),
    /// Gleam resolver stubs (file or directory)
    resolvers: Option(String),
    /// Gleam operation-based resolver boilerplate (directory only)
    operations: Option(String),
    /// Normalised SDL output (file only)
    sdl: Option(String),
  )
}

/// Gleam code generation options
pub type GleamConfig {
  GleamConfig(
    /// Module prefix for generated type files (e.g. "api/domain")
    types_module_prefix: String,
    /// Module prefix for generated resolver files (e.g. "api/schema")
    resolvers_module_prefix: String,
    /// Suffix for type filenames, without extension (default: "_types")
    /// e.g. "user.graphql" + "_types" → "user_types.gleam"
    type_suffix: String,
    /// Suffix for resolver filenames, without extension (default: "_resolvers")
    resolver_suffix: String,
    /// Extra import lines added to every generated resolver file.
    /// The types module import is always added automatically.
    /// Example: ["gleam/dynamic.{type Dynamic}", "mochi/schema.{type ExecutionContext}"]
    resolver_imports: List(String),
    /// Whether to add doc comments to generated code
    generate_docs: Bool,
  )
}

/// Whether an output path is a directory (ends with "/")
pub fn is_dir_output(path: String) -> Bool {
  string.ends_with(path, "/")
}

/// Create a default config
pub fn default() -> Config {
  Config(
    schema: ["schema.graphql"],
    operations_input: None,
    output: OutputConfig(
      typescript: Some("src/generated/types.ts"),
      gleam_types: Some("src/generated/"),
      resolvers: Some("src/generated/"),
      operations: None,
      sdl: None,
    ),
    gleam: GleamConfig(
      types_module_prefix: "generated",
      resolvers_module_prefix: "generated",
      type_suffix: "_types",
      resolver_suffix: "_resolvers",
      resolver_imports: [],
      generate_docs: True,
    ),
  )
}

/// Serialise config to a YAML string
pub fn to_yaml(config: Config) -> String {
  let schema_yaml = case config.schema {
    [single] -> "schema: \"" <> single <> "\"\n"
    many ->
      "schema:\n"
      <> string.join(list.map(many, fn(p) { "  - \"" <> p <> "\"" }), "\n")
      <> "\n"
  }

  let operations_input_yaml =
    opt_yaml_field("operations_input", config.operations_input)

  let output_yaml =
    "output:\n"
    <> opt_yaml_field("  typescript", config.output.typescript)
    <> opt_yaml_field("  gleam_types", config.output.gleam_types)
    <> opt_yaml_field("  resolvers", config.output.resolvers)
    <> opt_yaml_field("  operations", config.output.operations)
    <> opt_yaml_field("  sdl", config.output.sdl)

  let resolver_imports_yaml = case config.gleam.resolver_imports {
    [] -> ""
    imports ->
      "  resolver_imports:\n"
      <> string.join(list.map(imports, fn(i) { "    - \"" <> i <> "\"" }), "\n")
      <> "\n"
  }

  let gleam_yaml =
    "gleam:\n"
    <> "  types_module_prefix: \""
    <> config.gleam.types_module_prefix
    <> "\"\n"
    <> "  resolvers_module_prefix: \""
    <> config.gleam.resolvers_module_prefix
    <> "\"\n"
    <> "  type_suffix: \""
    <> config.gleam.type_suffix
    <> "\"\n"
    <> "  resolver_suffix: \""
    <> config.gleam.resolver_suffix
    <> "\"\n"
    <> resolver_imports_yaml
    <> "  generate_docs: "
    <> bool_to_yaml(config.gleam.generate_docs)
    <> "\n"

  schema_yaml
  <> "\n"
  <> operations_input_yaml
  <> "\n"
  <> output_yaml
  <> "\n"
  <> gleam_yaml
}

fn opt_yaml_field(key: String, value: Option(String)) -> String {
  case value {
    Some(v) -> key <> ": \"" <> v <> "\"\n"
    None -> ""
  }
}

fn bool_to_yaml(b: Bool) -> String {
  case b {
    True -> "true"
    False -> "false"
  }
}

import gleam/list
import gleam/result

/// Parse config from a YAML string
pub fn from_yaml(input: String) -> Result(Config, String) {
  case taffy.parse(input) {
    Error(e) -> Error("Failed to parse YAML: " <> e.message)
    Ok(doc) -> decode_config(doc)
  }
}

fn decode_config(doc: taffy.Value) -> Result(Config, String) {
  use schema <- result.try(decode_schema(doc))
  use output <- result.try(decode_output(doc))
  use gleam <- result.try(decode_gleam(doc))
  Ok(Config(
    schema:,
    operations_input: opt_string(doc, "operations_input"),
    output:,
    gleam:,
  ))
}

fn decode_schema(doc: taffy.Value) -> Result(List(String), String) {
  case taffy.get(doc, "schema") {
    Error(_) -> Error("missing required field \"schema\"")
    Ok(val) ->
      case taffy.as_list(val) {
        Some(items) -> {
          let strs =
            list.filter_map(items, fn(v) {
              case taffy.as_string(v) {
                Some(s) -> Ok(s)
                None -> Error(Nil)
              }
            })
          Ok(strs)
        }
        None ->
          case taffy.as_string(val) {
            Some(s) -> Ok([s])
            None -> Error("\"schema\" must be a string or list of strings")
          }
      }
  }
}

fn decode_output(doc: taffy.Value) -> Result(OutputConfig, String) {
  let output = case taffy.get(doc, "output") {
    Ok(v) -> v
    Error(_) -> taffy.mapping([])
  }
  Ok(OutputConfig(
    typescript: opt_string(output, "typescript"),
    gleam_types: opt_string(output, "gleam_types"),
    resolvers: opt_string(output, "resolvers"),
    operations: opt_string(output, "operations"),
    sdl: opt_string(output, "sdl"),
  ))
}

fn decode_gleam(doc: taffy.Value) -> Result(GleamConfig, String) {
  let g = case taffy.get(doc, "gleam") {
    Ok(v) -> v
    Error(_) -> taffy.mapping([])
  }
  Ok(GleamConfig(
    types_module_prefix: req_string(g, "types_module_prefix", "generated"),
    resolvers_module_prefix: req_string(
      g,
      "resolvers_module_prefix",
      "generated",
    ),
    type_suffix: req_string(g, "type_suffix", "_types"),
    resolver_suffix: req_string(g, "resolver_suffix", "_resolvers"),
    resolver_imports: opt_string_list(g, "resolver_imports"),
    generate_docs: req_bool(g, "generate_docs", True),
  ))
}

fn opt_string(val: taffy.Value, key: String) -> Option(String) {
  case taffy.get(val, key) {
    Ok(v) -> taffy.as_string(v)
    Error(_) -> None
  }
}

fn req_string(val: taffy.Value, key: String, default: String) -> String {
  case taffy.get(val, key) {
    Ok(v) ->
      case taffy.as_string(v) {
        Some(s) -> s
        None -> default
      }
    Error(_) -> default
  }
}

fn opt_string_list(val: taffy.Value, key: String) -> List(String) {
  case taffy.get(val, key) {
    Ok(v) ->
      case taffy.as_list(v) {
        Some(items) ->
          list.filter_map(items, fn(item) {
            option.to_result(taffy.as_string(item), Nil)
          })
        None -> []
      }
    Error(_) -> []
  }
}

fn req_bool(val: taffy.Value, key: String, default: Bool) -> Bool {
  case taffy.get(val, key) {
    Ok(v) ->
      case taffy.as_bool(v) {
        Some(b) -> b
        None -> default
      }
    Error(_) -> default
  }
}

/// Read config from the default config file
pub fn read() -> Result(Config, String) {
  read_from(config_file)
}

/// Read config from a specific path
pub fn read_from(path: String) -> Result(Config, String) {
  case simplifile.read(path) {
    Ok(content) -> from_yaml(content)
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
  case simplifile.write(path, to_yaml(config)) {
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
