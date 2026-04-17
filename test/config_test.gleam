// Tests for mochi_codegen/config.gleam

import gleam/option.{None, Some}
import gleam/string
import mochi_codegen/config
import simplifile

pub fn default_config_test() {
  let conf = config.default()
  case conf.schema {
    ["schema.graphql"] -> Nil
    _ -> panic as "Default schema should be schema.graphql"
  }
  case conf.output.typescript {
    Some(_) -> Nil
    None -> panic as "Default should include typescript output"
  }
  case conf.output.gleam_types {
    Some(_) -> Nil
    None -> panic as "Default should include gleam_types output"
  }
  case conf.output.resolvers {
    Some(_) -> Nil
    None -> panic as "Default should include resolvers output"
  }
  case conf.output.sdl {
    None -> Nil
    Some(_) -> panic as "Default should not include sdl output"
  }
  case conf.gleam.generate_docs {
    True -> Nil
    False -> panic as "Default should generate docs"
  }
}

pub fn to_yaml_produces_valid_yaml_test() {
  let yaml = config.to_yaml(config.default())

  case string.contains(yaml, "schema:") {
    True -> Nil
    False -> panic as "YAML should contain schema key"
  }
  case string.contains(yaml, "output:") {
    True -> Nil
    False -> panic as "YAML should contain output key"
  }
  case string.contains(yaml, "gleam:") {
    True -> Nil
    False -> panic as "YAML should contain gleam key"
  }
  case string.contains(yaml, "types_module_prefix:") {
    True -> Nil
    False -> panic as "YAML should contain types_module_prefix"
  }
}

pub fn roundtrip_default_config_test() {
  let original = config.default()
  let yaml = config.to_yaml(original)
  case config.from_yaml(yaml) {
    Ok(parsed) -> {
      case parsed.schema == original.schema {
        True -> Nil
        False -> panic as "Schema path should roundtrip"
      }
      case parsed.output.typescript == original.output.typescript {
        True -> Nil
        False -> panic as "Typescript output should roundtrip"
      }
      case parsed.output.sdl == original.output.sdl {
        True -> Nil
        False -> panic as "SDL output (None) should roundtrip"
      }
      case parsed.gleam.types_module_prefix == original.gleam.types_module_prefix {
        True -> Nil
        False -> panic as "types_module_prefix should roundtrip"
      }
      case parsed.gleam.generate_docs == original.gleam.generate_docs {
        True -> Nil
        False -> panic as "generate_docs should roundtrip"
      }
    }
    Error(msg) -> panic as { "Roundtrip failed: " <> msg }
  }
}

pub fn roundtrip_custom_config_test() {
  let conf =
    config.Config(
      schema: ["src/api.graphql"],
      output: config.OutputConfig(
        typescript: Some("out/types.ts"),
        gleam_types: None,
        resolvers: Some("out/resolvers.gleam"),
        sdl: Some("out/schema.graphql"),
      ),
      gleam: config.GleamConfig(
        types_module_prefix: "api_types",
        resolvers_module_prefix: "api_resolvers",
        type_suffix: "_types",
        resolver_suffix: "_resolvers",
        resolver_imports: [],
        generate_docs: False,
      ),
    )

  let yaml = config.to_yaml(conf)
  case config.from_yaml(yaml) {
    Ok(parsed) -> {
      case parsed.schema {
        ["src/api.graphql"] -> Nil
        _ -> panic as "Custom schema path should roundtrip"
      }
      case parsed.output.gleam_types {
        None -> Nil
        _ -> panic as "None gleam_types should roundtrip"
      }
      case parsed.output.sdl {
        Some("out/schema.graphql") -> Nil
        _ -> panic as "SDL output should roundtrip"
      }
      case parsed.gleam.generate_docs {
        False -> Nil
        True -> panic as "generate_docs=false should roundtrip"
      }
    }
    Error(msg) -> panic as { "Custom roundtrip failed: " <> msg }
  }
}

pub fn from_yaml_invalid_input_test() {
  case config.from_yaml(": invalid: {yaml") {
    Error(_) -> Nil
    Ok(_) -> panic as "Invalid YAML should return error"
  }
}

pub fn from_yaml_missing_schema_test() {
  case config.from_yaml("output:\n  typescript: out.ts\n") {
    Error(_) -> Nil
    Ok(_) -> panic as "Missing schema field should return error"
  }
}

pub fn write_and_read_config_test() {
  let path = "/tmp/mochi_test_config_" <> random_suffix() <> ".yaml"
  let conf = config.default()

  case config.write_to(conf, path) {
    Ok(_) -> Nil
    Error(msg) -> panic as { "Write failed: " <> msg }
  }

  case config.read_from(path) {
    Ok(parsed) -> {
      case parsed.schema == conf.schema {
        True -> Nil
        False -> panic as "Read config should match written config"
      }
    }
    Error(msg) -> panic as { "Read failed: " <> msg }
  }

  let _ = simplifile.delete(path)
  Nil
}

pub fn read_missing_file_test() {
  case config.read_from("/tmp/mochi_nonexistent_config.yaml") {
    Error(_) -> Nil
    Ok(_) -> panic as "Reading missing file should return error"
  }
}

pub fn to_yaml_omits_null_outputs_test() {
  let conf =
    config.Config(
      ..config.default(),
      output: config.OutputConfig(
        typescript: None,
        gleam_types: None,
        resolvers: None,
        sdl: None,
      ),
    )
  let yaml = config.to_yaml(conf)

  case string.contains(yaml, "typescript:") {
    False -> Nil
    True -> panic as "None typescript should be omitted from YAML"
  }
}

pub fn schema_as_list_roundtrip_test() {
  let conf =
    config.Config(
      ..config.default(),
      schema: ["graphql/user.graphql", "graphql/store.graphql"],
    )
  let yaml = config.to_yaml(conf)
  case config.from_yaml(yaml) {
    Ok(parsed) -> {
      case parsed.schema {
        ["graphql/user.graphql", "graphql/store.graphql"] -> Nil
        _ -> panic as "Multi-schema list should roundtrip"
      }
    }
    Error(msg) -> panic as { "Multi-schema roundtrip failed: " <> msg }
  }
}

@external(erlang, "erlang", "unique_integer")
fn unique_int() -> Int

fn random_suffix() -> String {
  let n = unique_int()
  case n < 0 {
    True -> string.inspect(-n)
    False -> string.inspect(n)
  }
}
