import gleam/dict
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import mochi/parser as mochi_parser
import mochi/schema.{type Schema}
import mochi/sdl_ast.{type SDLDocument, SDLDocument}
import mochi/sdl_parser
import mochi_codegen/config
import mochi_codegen/gleam as gleam_gen
import mochi_codegen/operation_gen
import mochi_codegen/sdl
import mochi_codegen/typescript
import simplifile

// ── Types ─────────────────────────────────────────────────────────────────────

/// Controls when an output file is (re)written.
pub type WritePolicy {
  /// Always write (SDL output, TypeScript).
  AlwaysWrite
  /// Write only when the generated content differs from the existing file.
  /// Used for type files — always up to date with the schema.
  OnlyIfChanged
  /// Never overwrite existing files. For new files, write in full.
  /// For existing files, append only stub functions not already present.
  /// Used for resolver files — developer-owned.
  MergeNewFunctions
}

pub type CliConfig {
  CliConfig(
    schema_paths: List(String),
    typescript_output: Result(String, Nil),
    gleam_output: Result(String, Nil),
    resolvers_output: Result(String, Nil),
    sdl_output: Result(String, Nil),
  )
}

pub type CliError {
  NoSchemaFile
  FileReadError(path: String, reason: String)
  ParseError(message: String)
  WriteError(path: String, reason: String)
  InvalidArgs(message: String)
}

// ── Entry points ──────────────────────────────────────────────────────────────

pub fn main() {
  case run() {
    Ok(msg) -> io.println(msg)
    Error(err) -> {
      io.println_error(format_error(err))
      halt(1)
    }
  }
}

pub fn run() -> Result(String, CliError) {
  run_with_args(get_args())
}

pub fn run_with_args(args: List(String)) -> Result(String, CliError) {
  case args {
    ["init", ..rest] -> run_init(rest)
    ["generate", ..rest] -> run_generate(rest)
    _ -> run_direct(args)
  }
}

// ── init ──────────────────────────────────────────────────────────────────────

fn run_init(args: List(String)) -> Result(String, CliError) {
  case args {
    ["--help"] | ["-h"] -> Ok(init_help_text())
    _ -> {
      case config.exists() {
        True ->
          Error(InvalidArgs(
            config.config_file
            <> " already exists. Delete it first to reinitialize.",
          ))
        False -> {
          let conf = case args {
            [pattern] -> config.Config(..config.default(), schema: [pattern])
            _ -> config.default()
          }
          case config.write(conf) {
            Ok(_) ->
              Ok(
                "Created "
                <> config.config_file
                <> "\n\nNext steps:\n"
                <> "  1. Edit "
                <> config.config_file
                <> " to match your project\n"
                <> "  2. Run: gleam run -m mochi_codegen/cli -- generate",
              )
            Error(msg) -> Error(WriteError(config.config_file, msg))
          }
        }
      }
    }
  }
}

// ── generate ──────────────────────────────────────────────────────────────────

fn run_generate(args: List(String)) -> Result(String, CliError) {
  case args {
    ["--help"] | ["-h"] -> Ok(generate_help_text())
    _ -> {
      let config_path = case args {
        ["--config", path] | ["-c", path] -> path
        _ -> config.config_file
      }

      use conf <- result.try(case config.read_from(config_path) {
        Ok(c) -> Ok(c)
        Error(msg) -> Error(InvalidArgs(msg))
      })

      use resolved_paths <- result.try(expand_globs(conf.schema))

      let gleam_config =
        gleam_gen.GleamGenConfig(
          types_module: conf.gleam.types_module_prefix,
          type_suffix: conf.gleam.type_suffix,
          resolvers_module: conf.gleam.resolvers_module_prefix,
          generate_resolvers: True,
          resolver_imports: conf.gleam.resolver_imports,
          generate_docs: conf.gleam.generate_docs,
        )

      use messages <- result.try(generate_from_paths(
        resolved_paths,
        conf.output,
        gleam_config,
        conf.gleam.type_suffix,
        conf.gleam.resolver_suffix,
        conf.operations_input,
      ))

      case messages {
        [] -> Ok("No outputs configured in " <> config_path)
        _ -> Ok(string.join(list.reverse(messages), "\n"))
      }
    }
  }
}

// ── direct mode ───────────────────────────────────────────────────────────────

fn run_direct(args: List(String)) -> Result(String, CliError) {
  use cli_config <- result.try(parse_args(args))
  use resolved_paths <- result.try(expand_globs(cli_config.schema_paths))

  let gleam_config = gleam_gen.default_config()

  let output =
    config.OutputConfig(
      typescript: option.from_result(cli_config.typescript_output),
      gleam_types: option.from_result(cli_config.gleam_output),
      resolvers: option.from_result(cli_config.resolvers_output),
      operations: None,
      sdl: option.from_result(cli_config.sdl_output),
    )

  use messages <- result.try(generate_from_paths(
    resolved_paths,
    output,
    gleam_config,
    "_types",
    "_resolvers",
    None,
  ))

  case messages {
    [] -> Ok("No output files specified. Use --help for usage.")
    _ -> Ok(string.join(list.reverse(messages), "\n"))
  }
}

// ── core generation ───────────────────────────────────────────────────────────

/// Generate outputs from a resolved (glob-expanded) list of schema file paths.
///
/// For directory outputs (path ending in "/"), one file is produced per schema
/// file. For file outputs, all schemas are merged into a single document.
fn generate_from_paths(
  paths: List(String),
  output: config.OutputConfig,
  gleam_config: gleam_gen.GleamGenConfig,
  type_suffix: String,
  resolver_suffix: String,
  operations_input: option.Option(String),
) -> Result(List(String), CliError) {
  use merged <- result.try(read_and_merge_schemas(paths))

  // Build type→module registry: for each source file, map each defined type
  // name to the full module path it will be generated into.
  use type_registry <- result.try(build_type_registry(
    paths,
    gleam_config.types_module,
    type_suffix,
  ))

  let messages = []

  // TypeScript — always overwrite (generated artifact)
  use messages <- result.try(case output.typescript {
    None -> Ok(messages)
    Some(path) ->
      write_single_or_dir(
        path,
        paths,
        merged,
        generate_typescript_from_sdl,
        type_suffix <> ".ts",
        messages,
        "Generated TypeScript",
        OnlyIfChanged,
      )
  })

  // Gleam types — overwrite only when content changed (generated artifact)
  use messages <- result.try(case output.gleam_types {
    None -> Ok(messages)
    Some(path) ->
      write_single_or_dir_mapped(
        path,
        paths,
        merged,
        fn(doc) { gleam_gen.generate_types(doc, gleam_config) },
        fn(src_path) {
          let current_module =
            gleam_config.types_module
            <> "/"
            <> schema_stem(src_path)
            <> type_suffix
          let filtered_registry =
            list.filter(type_registry, fn(pair) { pair.1 != current_module })
          fn(doc) {
            gleam_gen.generate_types_with_registry(
              doc,
              gleam_config,
              filtered_registry,
            )
          }
        },
        type_suffix <> ".gleam",
        messages,
        "Generated Gleam types",
        OnlyIfChanged,
      )
  })

  // Gleam resolvers — only create if file doesn't exist (developer-owned)
  use messages <- result.try(case output.resolvers {
    None -> Ok(messages)
    Some(path) -> {
      write_single_or_dir_mapped(
        path,
        paths,
        merged,
        fn(doc) { gleam_gen.generate_resolvers(doc, gleam_config) },
        fn(src_path) {
          let current_module =
            gleam_config.types_module
            <> "/"
            <> schema_stem(src_path)
            <> type_suffix
          let filtered_registry =
            list.filter(type_registry, fn(pair) { pair.1 != current_module })
          fn(doc) {
            gleam_gen.generate_resolvers_with_registry(
              doc,
              gleam_config,
              filtered_registry,
            )
          }
        },
        resolver_suffix <> ".gleam",
        messages,
        "Generated resolvers",
        MergeNewFunctions,
      )
    }
  })

  // Operations — read .gql operation files, generate resolver boilerplate
  use messages <- result.try(case operations_input, output.operations {
    Some(input_glob), Some(out_path) -> {
      use op_paths <- result.try(expand_globs([input_glob]))
      list.try_fold(op_paths, messages, fn(msgs, op_path) {
        use content <- result.try(
          simplifile.read(op_path)
          |> result.map_error(fn(_) {
            FileReadError(op_path, "File system error")
          }),
        )
        use ops_doc <- result.try(
          mochi_parser.parse(content)
          |> result.map_error(fn(e) { ParseError(format_op_parse_error(e)) }),
        )
        let generated = operation_gen.generate(ops_doc, merged)
        let filename = schema_stem(op_path) <> resolver_suffix <> ".gleam"
        let dest = out_path <> filename
        use _ <- result.try(ensure_dir(out_path))
        use written <- result.try(write_with_policy(
          dest,
          generated,
          MergeNewFunctions,
        ))
        let msg = case written {
          True -> "Generated operations: " <> dest
          False -> "Generated operations (up to date): " <> dest
        }
        Ok([msg, ..msgs])
      })
    }
    _, _ -> Ok(messages)
  })

  // SDL — always single file (merging makes sense here)
  use messages <- result.try(case output.sdl {
    None -> Ok(messages)
    Some(path) -> {
      use _ <- result.try(write_file(path, generate_sdl_from_sdl(merged)))
      Ok(["Generated SDL: " <> path, ..messages])
    }
  })

  Ok(messages)
}

/// Write output either as a single merged file or as per-schema files in a directory.
fn write_single_or_dir(
  output_path: String,
  source_paths: List(String),
  merged: SDLDocument,
  generate: fn(SDLDocument) -> String,
  suffix: String,
  messages: List(String),
  label: String,
  policy: WritePolicy,
) -> Result(List(String), CliError) {
  case config.is_dir_output(output_path) {
    False -> {
      use written <- result.try(write_with_policy(
        output_path,
        generate(merged),
        policy,
      ))
      let msg = case written {
        True -> label <> ": " <> output_path
        False -> label <> " (up to date): " <> output_path
      }
      Ok([msg, ..messages])
    }
    True -> {
      use msgs <- result.try(
        list.try_fold(source_paths, messages, fn(msgs, src_path) {
          use doc <- result.try(read_and_parse_schema(src_path))
          let filename = schema_filename(src_path, suffix)
          let out_path = output_path <> filename
          use _ <- result.try(ensure_dir(output_path))
          use written <- result.try(write_with_policy(
            out_path,
            generate(doc),
            policy,
          ))
          let msg = case written {
            True -> label <> ": " <> out_path
            False -> label <> " (up to date): " <> out_path
          }
          Ok([msg, ..msgs])
        }),
      )
      Ok(msgs)
    }
  }
}

/// Extract the stem from a schema path: "graphql/user.graphql" → "user"
fn schema_stem(schema_path: String) -> String {
  schema_path
  |> string.split("/")
  |> list.last
  |> result.unwrap(schema_path)
  |> string.split(".")
  |> list.first
  |> result.unwrap(schema_path)
}

/// Derive output filename from schema path: "graphql/user.graphql" → "user<suffix>"
fn schema_filename(schema_path: String, suffix: String) -> String {
  schema_stem(schema_path) <> suffix
}

/// Like write_single_or_dir but accepts a per-file generator factory for directory mode.
fn write_single_or_dir_mapped(
  output_path: String,
  source_paths: List(String),
  merged: SDLDocument,
  generate_single: fn(SDLDocument) -> String,
  make_generator: fn(String) -> fn(SDLDocument) -> String,
  suffix: String,
  messages: List(String),
  label: String,
  policy: WritePolicy,
) -> Result(List(String), CliError) {
  case config.is_dir_output(output_path) {
    False -> {
      use written <- result.try(write_with_policy(
        output_path,
        generate_single(merged),
        policy,
      ))
      let msg = case written {
        True -> label <> ": " <> output_path
        False -> label <> " (up to date): " <> output_path
      }
      Ok([msg, ..messages])
    }
    True -> {
      use msgs <- result.try(
        list.try_fold(source_paths, messages, fn(msgs, src_path) {
          use doc <- result.try(read_and_parse_schema(src_path))
          let filename = schema_filename(src_path, suffix)
          let out_path = output_path <> filename
          use _ <- result.try(ensure_dir(output_path))
          use written <- result.try(write_with_policy(
            out_path,
            make_generator(src_path)(doc),
            policy,
          ))
          let msg = case written {
            True -> label <> ": " <> out_path
            False -> label <> " (up to date): " <> out_path
          }
          Ok([msg, ..msgs])
        }),
      )
      Ok(msgs)
    }
  }
}

// ── glob expansion ────────────────────────────────────────────────────────────

/// Expand a list of glob patterns / literal paths into concrete file paths.
pub fn expand_globs(patterns: List(String)) -> Result(List(String), CliError) {
  case patterns {
    [] -> Error(NoSchemaFile)
    _ -> {
      let paths =
        patterns
        |> list.flat_map(fn(p) {
          case glob(p) {
            [] -> [p]
            matched -> matched
          }
        })
        |> list.unique
      case paths {
        [] -> Error(NoSchemaFile)
        _ -> Ok(paths)
      }
    }
  }
}

@external(erlang, "mochi_codegen_ffi", "glob")
fn glob(pattern: String) -> List(String)

// ── schema reading ────────────────────────────────────────────────────────────

/// Read and merge multiple schema files into one document.
pub fn read_and_merge_schemas(
  paths: List(String),
) -> Result(SDLDocument, CliError) {
  case paths {
    [] -> Error(NoSchemaFile)
    _ ->
      paths
      |> list.try_map(read_and_parse_schema)
      |> result.map(fn(docs) {
        let defs = list.flat_map(docs, fn(d) { d.definitions })
        SDLDocument(definitions: apply_extensions(defs))
      })
  }
}

fn apply_extensions(
  defs: List(sdl_ast.TypeSystemDefinition),
) -> List(sdl_ast.TypeSystemDefinition) {
  let #(base_defs, extensions) =
    list.partition(defs, fn(def) {
      case def {
        sdl_ast.TypeExtension(_) -> False
        _ -> True
      }
    })

  let ext_map =
    list.fold(extensions, dict.new(), fn(acc, def) {
      case def {
        sdl_ast.TypeExtension(ext) ->
          dict.upsert(acc, sdl_ast.get_extension_name(ext), fn(existing) {
            case existing {
              option.None -> [ext]
              option.Some(exts) -> [ext, ..exts]
            }
          })
        _ -> acc
      }
    })

  let merged =
    list.map(base_defs, fn(def) {
      case def {
        sdl_ast.TypeDefinition(type_def) -> {
          let name = sdl_ast.get_type_name(type_def)
          case dict.get(ext_map, name) {
            Error(_) -> def
            Ok(exts) ->
              sdl_ast.TypeDefinition(merge_extensions(
                type_def,
                list.reverse(exts),
              ))
          }
        }
        _ -> def
      }
    })

  let merged_name_set =
    list.fold(merged, dict.new(), fn(acc, def) {
      case def {
        sdl_ast.TypeDefinition(type_def) ->
          dict.insert(acc, sdl_ast.get_type_name(type_def), Nil)
        _ -> acc
      }
    })

  let orphan_map =
    list.fold(extensions, dict.new(), fn(acc, def) {
      case def {
        sdl_ast.TypeExtension(ext) -> {
          let name = sdl_ast.get_extension_name(ext)
          case dict.has_key(merged_name_set, name) {
            True -> acc
            False ->
              dict.upsert(acc, name, fn(existing) {
                case existing {
                  option.None -> [ext]
                  option.Some(exts) -> [ext, ..exts]
                }
              })
          }
        }
        _ -> acc
      }
    })

  let orphans =
    dict.to_list(orphan_map)
    |> list.sort(fn(a, b) { string.compare(a.0, b.0) })
    |> list.filter_map(fn(pair) {
      case list.reverse(pair.1) {
        [] -> Error(Nil)
        [first, ..rest] ->
          Ok(
            sdl_ast.TypeDefinition(merge_extensions(
              extension_to_type_def(first),
              rest,
            )),
          )
      }
    })

  list.append(merged, orphans)
}

fn name_set(names: List(String)) -> dict.Dict(String, Nil) {
  list.fold(names, dict.new(), fn(acc, n) { dict.insert(acc, n, Nil) })
}

fn merge_extensions(
  type_def: sdl_ast.TypeDef,
  exts: List(sdl_ast.TypeExtensionDef),
) -> sdl_ast.TypeDef {
  list.fold(exts, type_def, fn(td, ext) {
    case td, ext {
      sdl_ast.ObjectTypeDefinition(obj),
        sdl_ast.ObjectTypeExtension(_, interfaces, directives, fields)
      -> {
        let existing_fields = name_set(list.map(obj.fields, fn(f) { f.name }))
        let existing_interfaces = name_set(obj.interfaces)
        let new_fields =
          list.filter(fields, fn(f) { !dict.has_key(existing_fields, f.name) })
        let new_interfaces =
          list.filter(interfaces, fn(i) {
            !dict.has_key(existing_interfaces, i)
          })
        sdl_ast.ObjectTypeDefinition(
          sdl_ast.ObjectTypeDef(
            ..obj,
            interfaces: list.append(obj.interfaces, new_interfaces),
            directives: list.append(obj.directives, directives),
            fields: list.append(obj.fields, new_fields),
          ),
        )
      }
      sdl_ast.InterfaceTypeDefinition(iface),
        sdl_ast.InterfaceTypeExtension(_, directives, fields)
      -> {
        let existing_fields = name_set(list.map(iface.fields, fn(f) { f.name }))
        let new_fields =
          list.filter(fields, fn(f) { !dict.has_key(existing_fields, f.name) })
        sdl_ast.InterfaceTypeDefinition(
          sdl_ast.InterfaceTypeDef(
            ..iface,
            directives: list.append(iface.directives, directives),
            fields: list.append(iface.fields, new_fields),
          ),
        )
      }
      sdl_ast.UnionTypeDefinition(union),
        sdl_ast.UnionTypeExtension(_, directives, member_types)
      -> {
        let existing_members = name_set(union.member_types)
        let new_members =
          list.filter(member_types, fn(m) { !dict.has_key(existing_members, m) })
        sdl_ast.UnionTypeDefinition(
          sdl_ast.UnionTypeDef(
            ..union,
            directives: list.append(union.directives, directives),
            member_types: list.append(union.member_types, new_members),
          ),
        )
      }
      sdl_ast.EnumTypeDefinition(enum_def),
        sdl_ast.EnumTypeExtension(_, directives, values)
      -> {
        let existing_values =
          name_set(list.map(enum_def.values, fn(v) { v.name }))
        let new_values =
          list.filter(values, fn(v) { !dict.has_key(existing_values, v.name) })
        sdl_ast.EnumTypeDefinition(
          sdl_ast.EnumTypeDef(
            ..enum_def,
            directives: list.append(enum_def.directives, directives),
            values: list.append(enum_def.values, new_values),
          ),
        )
      }
      sdl_ast.InputObjectTypeDefinition(input),
        sdl_ast.InputObjectTypeExtension(_, directives, fields)
      -> {
        let existing_fields = name_set(list.map(input.fields, fn(f) { f.name }))
        let new_fields =
          list.filter(fields, fn(f) { !dict.has_key(existing_fields, f.name) })
        sdl_ast.InputObjectTypeDefinition(
          sdl_ast.InputObjectTypeDef(
            ..input,
            directives: list.append(input.directives, directives),
            fields: list.append(input.fields, new_fields),
          ),
        )
      }
      sdl_ast.ScalarTypeDefinition(scalar),
        sdl_ast.ScalarTypeExtension(_, directives)
      ->
        sdl_ast.ScalarTypeDefinition(
          sdl_ast.ScalarTypeDef(
            ..scalar,
            directives: list.append(scalar.directives, directives),
          ),
        )
      _, _ -> {
        io.println_error(
          "warning: extension kind does not match base type '"
          <> sdl_ast.get_extension_name(ext)
          <> "', skipping",
        )
        td
      }
    }
  })
}

fn extension_to_type_def(ext: sdl_ast.TypeExtensionDef) -> sdl_ast.TypeDef {
  case ext {
    sdl_ast.ObjectTypeExtension(name, interfaces, directives, fields) ->
      sdl_ast.ObjectTypeDefinition(sdl_ast.ObjectTypeDef(
        name: name,
        description: option.None,
        interfaces: interfaces,
        directives: directives,
        fields: fields,
      ))
    sdl_ast.InterfaceTypeExtension(name, directives, fields) ->
      sdl_ast.InterfaceTypeDefinition(sdl_ast.InterfaceTypeDef(
        name: name,
        description: option.None,
        directives: directives,
        fields: fields,
      ))
    sdl_ast.UnionTypeExtension(name, directives, member_types) ->
      sdl_ast.UnionTypeDefinition(sdl_ast.UnionTypeDef(
        name: name,
        description: option.None,
        directives: directives,
        member_types: member_types,
      ))
    sdl_ast.EnumTypeExtension(name, directives, values) ->
      sdl_ast.EnumTypeDefinition(sdl_ast.EnumTypeDef(
        name: name,
        description: option.None,
        directives: directives,
        values: values,
      ))
    sdl_ast.InputObjectTypeExtension(name, directives, fields) ->
      sdl_ast.InputObjectTypeDefinition(sdl_ast.InputObjectTypeDef(
        name: name,
        description: option.None,
        directives: directives,
        fields: fields,
      ))
    sdl_ast.ScalarTypeExtension(name, directives) ->
      sdl_ast.ScalarTypeDefinition(sdl_ast.ScalarTypeDef(
        name: name,
        description: option.None,
        directives: directives,
      ))
  }
}

fn read_and_parse_schema(path: String) -> Result(SDLDocument, CliError) {
  use content <- result.try(
    simplifile.read(path)
    |> result.map_error(fn(_) { FileReadError(path, "File system error") }),
  )
  sdl_parser.parse_sdl(content)
  |> result.map_error(fn(e) { ParseError(format_parse_error(e)) })
}

// ── arg parsing ───────────────────────────────────────────────────────────────

fn parse_args(args: List(String)) -> Result(CliConfig, CliError) {
  case args {
    [] | ["--help"] | ["-h"] -> Error(InvalidArgs(help_text()))
    _ -> collect_schema_paths(args, [])
  }
}

fn collect_schema_paths(
  args: List(String),
  paths: List(String),
) -> Result(CliConfig, CliError) {
  case args {
    [] ->
      case paths {
        [] -> Error(InvalidArgs(help_text()))
        _ ->
          Ok(CliConfig(
            schema_paths: list.reverse(paths),
            typescript_output: Error(Nil),
            gleam_output: Error(Nil),
            resolvers_output: Error(Nil),
            sdl_output: Error(Nil),
          ))
      }
    [arg, ..rest] -> {
      case is_option_flag(arg) {
        True ->
          case paths {
            [] -> Error(InvalidArgs("Expected a schema file before options"))
            _ -> {
              let base =
                CliConfig(
                  schema_paths: list.reverse(paths),
                  typescript_output: Error(Nil),
                  gleam_output: Error(Nil),
                  resolvers_output: Error(Nil),
                  sdl_output: Error(Nil),
                )
              parse_options_loop(base, [arg, ..rest])
            }
          }
        False -> collect_schema_paths(rest, [arg, ..paths])
      }
    }
  }
}

fn is_option_flag(s: String) -> Bool {
  string.starts_with(s, "-")
}

fn parse_options_loop(
  cfg: CliConfig,
  options: List(String),
) -> Result(CliConfig, CliError) {
  case options {
    [] -> Ok(cfg)

    ["--typescript", path, ..rest] | ["-t", path, ..rest] ->
      parse_options_loop(CliConfig(..cfg, typescript_output: Ok(path)), rest)

    ["--gleam", path, ..rest] | ["-g", path, ..rest] ->
      parse_options_loop(CliConfig(..cfg, gleam_output: Ok(path)), rest)

    ["--resolvers", path, ..rest] | ["-r", path, ..rest] ->
      parse_options_loop(CliConfig(..cfg, resolvers_output: Ok(path)), rest)

    ["--sdl", path, ..rest] | ["-s", path, ..rest] ->
      parse_options_loop(CliConfig(..cfg, sdl_output: Ok(path)), rest)

    ["--all", prefix, ..rest] | ["-a", prefix, ..rest] ->
      parse_options_loop(
        CliConfig(
          ..cfg,
          typescript_output: Ok(prefix <> ".ts"),
          gleam_output: Ok(prefix <> "_types.gleam"),
          resolvers_output: Ok(prefix <> "_resolvers.gleam"),
          sdl_output: Ok(prefix <> ".graphql"),
        ),
        rest,
      )

    [unknown, ..] -> Error(InvalidArgs("Unknown option: " <> unknown))
  }
}

// ── type registry ─────────────────────────────────────────────────────────────

/// Build a registry mapping every GraphQL type name to the Gleam module path
/// it will be generated into. Used for cross-file imports in directory mode.
fn build_type_registry(
  paths: List(String),
  types_module: String,
  type_suffix: String,
) -> Result(List(#(String, String)), CliError) {
  list.try_map(paths, fn(path) {
    use doc <- result.try(read_and_parse_schema(path))
    let module = types_module <> "/" <> schema_stem(path) <> type_suffix
    Ok(
      list.map(gleam_gen.collect_defined_names(doc), fn(name) {
        #(name, module)
      }),
    )
  })
  |> result.map(list.flatten)
}

// ── file helpers ──────────────────────────────────────────────────────────────

fn ensure_dir(path: String) -> Result(Nil, CliError) {
  simplifile.create_directory_all(path)
  |> result.map_error(fn(_) { WriteError(path, "File system error") })
}

fn write_file(path: String, content: String) -> Result(Nil, CliError) {
  simplifile.write(path, content)
  |> result.map_error(fn(_) { WriteError(path, "File system error") })
}

/// Write according to policy. Returns Ok(True) if the file was written, Ok(False) if skipped.
fn write_with_policy(
  path: String,
  content: String,
  policy: WritePolicy,
) -> Result(Bool, CliError) {
  case policy {
    AlwaysWrite -> {
      use _ <- result.try(write_file(path, content))
      Ok(True)
    }
    OnlyIfChanged -> {
      let existing = simplifile.read(path)
      case existing {
        Ok(current) if current == content -> Ok(False)
        _ -> {
          use _ <- result.try(write_file(path, content))
          Ok(True)
        }
      }
    }
    MergeNewFunctions -> {
      case simplifile.read(path) {
        Error(_) -> {
          use _ <- result.try(write_file(path, content))
          Ok(True)
        }
        Ok(existing) -> {
          let additions = new_function_stubs(existing, content)
          case additions {
            "" -> Ok(False)
            _ -> {
              use _ <- result.try(write_file(path, existing <> additions))
              Ok(True)
            }
          }
        }
      }
    }
  }
}

fn new_function_stubs(existing: String, generated: String) -> String {
  let blocks = extract_pub_fn_blocks(generated)
  blocks
  |> list.filter(fn(block) {
    let name = fn_name_from_block(block)
    !string.contains(existing, "pub fn " <> name)
  })
  |> string.join("\n\n")
  |> fn(s) {
    case s {
      "" -> ""
      _ -> "\n\n" <> s
    }
  }
}

fn extract_pub_fn_blocks(src: String) -> List(String) {
  let parts = string.split(src, "\npub fn ")
  case parts {
    [] | [_] -> []
    [_, ..rest] ->
      list.map(rest, fn(part) { "pub fn " <> part })
      |> list.map(fn(block) {
        case string.split(block, "\npub fn ") {
          [first, ..] -> string.trim_end(first)
          [] -> block
        }
      })
  }
}

fn fn_name_from_block(block: String) -> String {
  block
  |> string.drop_start(string.length("pub fn "))
  |> string.split("(")
  |> list.first
  |> result.unwrap("")
}

// ── code generators ───────────────────────────────────────────────────────────

fn generate_typescript_from_sdl(doc: SDLDocument) -> String {
  let header = "// Generated by mochi - DO NOT EDIT\n\n"
  let scalars =
    "export type Maybe<T> = T | null | undefined;\n\n"
    <> "export type Scalars = {\n"
    <> "  ID: string;\n  String: string;\n  Int: number;\n"
    <> "  Float: number;\n  Boolean: boolean;\n};\n\n"

  let types =
    doc.definitions
    |> list.filter_map(fn(def) {
      case def {
        sdl_ast.TypeDefinition(td) -> Ok(type_def_to_typescript(td))
        _ -> Error(Nil)
      }
    })
    |> string.join("\n\n")

  header <> scalars <> types
}

fn type_def_to_typescript(td: sdl_ast.TypeDef) -> String {
  case td {
    sdl_ast.ObjectTypeDefinition(obj) -> object_to_typescript(obj)
    sdl_ast.InterfaceTypeDefinition(iface) -> interface_to_typescript(iface)
    sdl_ast.EnumTypeDefinition(e) -> enum_to_typescript(e)
    sdl_ast.InputObjectTypeDefinition(i) -> input_to_typescript(i)
    sdl_ast.UnionTypeDefinition(u) -> union_to_typescript(u)
    sdl_ast.ScalarTypeDefinition(s) -> "export type " <> s.name <> " = string;"
  }
}

fn object_to_typescript(obj: sdl_ast.ObjectTypeDef) -> String {
  let fields = obj.fields |> list.map(field_to_typescript) |> string.join("\n")
  "export interface " <> obj.name <> " {\n" <> fields <> "\n}"
}

fn interface_to_typescript(iface: sdl_ast.InterfaceTypeDef) -> String {
  let fields =
    iface.fields |> list.map(field_to_typescript) |> string.join("\n")
  "export interface " <> iface.name <> " {\n" <> fields <> "\n}"
}

fn field_to_typescript(f: sdl_ast.FieldDef) -> String {
  let opt = case is_non_null(f.field_type) {
    True -> ""
    False -> "?"
  }
  "  " <> f.name <> opt <> ": " <> sdl_type_to_ts(f.field_type) <> ";"
}

fn enum_to_typescript(e: sdl_ast.EnumTypeDef) -> String {
  let vals =
    e.values
    |> list.map(fn(v) { "  " <> v.name <> " = \"" <> v.name <> "\"," })
    |> string.join("\n")
  "export enum " <> e.name <> " {\n" <> vals <> "\n}"
}

fn input_to_typescript(i: sdl_ast.InputObjectTypeDef) -> String {
  let fields =
    i.fields
    |> list.map(fn(f) {
      let opt = case is_non_null(f.field_type) {
        True -> ""
        False -> "?"
      }
      "  " <> f.name <> opt <> ": " <> sdl_type_to_ts(f.field_type) <> ";"
    })
    |> string.join("\n")
  "export interface " <> i.name <> " {\n" <> fields <> "\n}"
}

fn union_to_typescript(u: sdl_ast.UnionTypeDef) -> String {
  "export type " <> u.name <> " = " <> string.join(u.member_types, " | ") <> ";"
}

fn sdl_type_to_ts(t: sdl_ast.SDLType) -> String {
  case t {
    sdl_ast.NamedType(name) ->
      case name {
        "String" -> "Scalars[\"String\"]"
        "Int" -> "Scalars[\"Int\"]"
        "Float" -> "Scalars[\"Float\"]"
        "Boolean" -> "Scalars[\"Boolean\"]"
        "ID" -> "Scalars[\"ID\"]"
        other -> other
      }
    sdl_ast.NonNullType(inner) -> sdl_type_to_ts(inner)
    sdl_ast.ListType(inner) -> "Maybe<" <> sdl_type_to_ts(inner) <> ">[]"
  }
}

fn is_non_null(t: sdl_ast.SDLType) -> Bool {
  case t {
    sdl_ast.NonNullType(_) -> True
    _ -> False
  }
}

fn generate_sdl_from_sdl(doc: SDLDocument) -> String {
  let types =
    doc.definitions
    |> list.filter_map(fn(def) {
      case def {
        sdl_ast.TypeDefinition(td) -> Ok(type_def_to_sdl(td))
        _ -> Error(Nil)
      }
    })
    |> string.join("\n\n")
  "# Generated by mochi\n\n" <> types
}

fn type_def_to_sdl(td: sdl_ast.TypeDef) -> String {
  case td {
    sdl_ast.ObjectTypeDefinition(obj) -> object_to_sdl(obj)
    sdl_ast.InterfaceTypeDefinition(iface) -> interface_to_sdl(iface)
    sdl_ast.EnumTypeDefinition(e) -> enum_to_sdl(e)
    sdl_ast.InputObjectTypeDefinition(i) -> input_to_sdl(i)
    sdl_ast.UnionTypeDefinition(u) -> union_to_sdl(u)
    sdl_ast.ScalarTypeDefinition(s) ->
      opt_desc(s.description) <> "scalar " <> s.name
  }
}

fn object_to_sdl(obj: sdl_ast.ObjectTypeDef) -> String {
  let implements = case obj.interfaces {
    [] -> ""
    ifaces -> " implements " <> string.join(ifaces, " & ")
  }
  let fields = obj.fields |> list.map(field_to_sdl) |> string.join("\n")
  opt_desc(obj.description)
  <> "type "
  <> obj.name
  <> implements
  <> " {\n"
  <> fields
  <> "\n}"
}

fn interface_to_sdl(iface: sdl_ast.InterfaceTypeDef) -> String {
  let fields = iface.fields |> list.map(field_to_sdl) |> string.join("\n")
  opt_desc(iface.description)
  <> "interface "
  <> iface.name
  <> " {\n"
  <> fields
  <> "\n}"
}

fn field_to_sdl(f: sdl_ast.FieldDef) -> String {
  let args = case f.arguments {
    [] -> ""
    args -> "(" <> string.join(list.map(args, arg_to_sdl), ", ") <> ")"
  }
  case f.description {
    Some(d) -> "  \"" <> d <> "\"\n"
    None -> ""
  }
  <> "  "
  <> f.name
  <> args
  <> ": "
  <> sdl_type_to_string(f.field_type)
}

fn arg_to_sdl(a: sdl_ast.ArgumentDef) -> String {
  a.name <> ": " <> sdl_type_to_string(a.arg_type)
}

fn enum_to_sdl(e: sdl_ast.EnumTypeDef) -> String {
  let vals = e.values |> list.map(fn(v) { "  " <> v.name }) |> string.join("\n")
  opt_desc(e.description) <> "enum " <> e.name <> " {\n" <> vals <> "\n}"
}

fn input_to_sdl(i: sdl_ast.InputObjectTypeDef) -> String {
  let fields =
    i.fields
    |> list.map(fn(f) {
      "  " <> f.name <> ": " <> sdl_type_to_string(f.field_type)
    })
    |> string.join("\n")
  opt_desc(i.description) <> "input " <> i.name <> " {\n" <> fields <> "\n}"
}

fn union_to_sdl(u: sdl_ast.UnionTypeDef) -> String {
  opt_desc(u.description)
  <> "union "
  <> u.name
  <> " = "
  <> string.join(u.member_types, " | ")
}

fn opt_desc(desc: option.Option(String)) -> String {
  case desc {
    Some(d) -> "\"\"\"" <> d <> "\"\"\"\n"
    None -> ""
  }
}

fn sdl_type_to_string(t: sdl_ast.SDLType) -> String {
  case t {
    sdl_ast.NamedType(name) -> name
    sdl_ast.NonNullType(inner) -> sdl_type_to_string(inner) <> "!"
    sdl_ast.ListType(inner) -> "[" <> sdl_type_to_string(inner) <> "]"
  }
}

// ── error formatting ──────────────────────────────────────────────────────────

fn format_error(err: CliError) -> String {
  case err {
    NoSchemaFile -> "Error: No schema file found"
    FileReadError(path, reason) -> "Error reading '" <> path <> "': " <> reason
    ParseError(msg) -> "Parse error: " <> msg
    WriteError(path, reason) -> "Error writing '" <> path <> "': " <> reason
    InvalidArgs(msg) -> msg
  }
}

fn format_op_parse_error(err: mochi_parser.ParseError) -> String {
  case err {
    mochi_parser.UnexpectedToken(expected, _, pos) ->
      "Unexpected token at line "
      <> int.to_string(pos.line)
      <> ", expected "
      <> expected
    mochi_parser.UnexpectedEOF(expected) ->
      "Unexpected end of file, expected " <> expected
    mochi_parser.LexError(_) -> "Lexer error"
  }
}

fn format_parse_error(err: sdl_parser.SDLParseError) -> String {
  case err {
    sdl_parser.SDLLexError(_) -> "Lexer error"
    sdl_parser.UnexpectedToken(expected, _, pos) ->
      "Unexpected token at line "
      <> int.to_string(pos.line)
      <> ", expected "
      <> expected
    sdl_parser.UnexpectedEOF(expected) ->
      "Unexpected end of file, expected " <> expected
    sdl_parser.InvalidTypeDefinition(msg, pos) ->
      "Invalid type at line " <> int.to_string(pos.line) <> ": " <> msg
  }
}

// ── help text ─────────────────────────────────────────────────────────────────

fn help_text() -> String {
  "mochi - GraphQL Code Generator for Gleam

Usage:
  gleam run -m mochi_codegen/cli -- <command>

Commands:
  init                               Create mochi.config.json
  generate                           Generate code from config
  <schema(s)> [opts]                 Direct mode (glob or file list)

Direct Mode Options:
  --typescript, -t <path>   TypeScript output (file or dir/)
  --gleam, -g <path>        Gleam types output (file or dir/)
  --resolvers, -r <path>    Gleam resolver stubs (file or dir/)
  --sdl, -s <file>          Normalised SDL output
  --all, -a <prefix>        Generate all files with prefix
  --help, -h                Show this help

Examples:
  gleam run -m mochi_codegen/cli -- generate
  gleam run -m mochi_codegen/cli -- 'graphql/*.graphql' -g src/api/domain/ -t src/generated/types.ts
  gleam run -m mochi_codegen/cli -- user.graphql store.graphql -g src/domain/
"
}

fn init_help_text() -> String {
  "mochi init - Initialize a mochi project

Usage:
  gleam run -m mochi_codegen/cli -- init [schema_glob]

Creates mochi.config.json. Optionally specify a schema glob (default: schema.graphql).

Examples:
  gleam run -m mochi_codegen/cli -- init
  gleam run -m mochi_codegen/cli -- init 'graphql/*.graphql'
"
}

fn generate_help_text() -> String {
  "mochi generate - Generate code from mochi.config.json

Usage:
  gleam run -m mochi_codegen/cli -- generate [options]

The \"schema\" field accepts a glob string or an array of globs/paths.
Output paths ending in \"/\" produce one file per source schema file.

Options:
  --config, -c <file>   Use a custom config file path
  --help, -h            Show this help
"
}

// ── FFI ───────────────────────────────────────────────────────────────────────

@external(erlang, "erlang", "halt")
fn halt(code: Int) -> Nil

@external(erlang, "mochi_ffi", "get_args")
fn get_args() -> List(String)

// For programmatic use

pub fn typescript(schema: Schema) -> String {
  typescript.generate(schema)
}

pub fn sdl(schema: Schema) -> String {
  sdl.generate(schema)
}

pub fn print_typescript(schema: Schema) -> Nil {
  io.println(typescript.generate(schema))
}

pub fn print_sdl(schema: Schema) -> Nil {
  io.println(sdl.generate(schema))
}
