import gleam/list
import gleam/string
import mochi/sdl_ast
import mochi_codegen/cli
import simplifile

fn merge(sdl_list: List(String)) -> sdl_ast.SDLDocument {
  let paths =
    list.index_map(sdl_list, fn(content, i) {
      let path = "/tmp/mochi_extend_test_" <> string.inspect(i) <> ".graphql"
      let assert Ok(_) = simplifile.write(path, content)
      path
    })
  case cli.read_and_merge_schemas(paths) {
    Ok(doc) -> doc
    Error(e) -> panic as { "Merge failed: " <> string.inspect(e) }
  }
}

fn find_type(doc: sdl_ast.SDLDocument, name: String) -> sdl_ast.TypeDef {
  case
    list.find(doc.definitions, fn(def) {
      case def {
        sdl_ast.TypeDefinition(td) -> sdl_ast.get_type_name(td) == name
        _ -> False
      }
    })
  {
    Ok(sdl_ast.TypeDefinition(td)) -> td
    _ -> panic as { "Type not found: " <> name }
  }
}

pub fn extend_merges_fields_test() {
  let doc =
    merge([
      "type Mutation { login(email: String!, password: String!): String! }",
      "extend type Mutation { finalizeTournament(tournamentId: ID!): String! }",
    ])
  case find_type(doc, "Mutation") {
    sdl_ast.ObjectTypeDefinition(obj) -> {
      let assert 2 = list.length(obj.fields)
    }
    _ -> panic as "Expected ObjectTypeDefinition"
  }
}

pub fn extend_no_duplicate_fields_test() {
  let doc =
    merge([
      "type Query { me: String }",
      "extend type Query { me: String }",
    ])
  case find_type(doc, "Query") {
    sdl_ast.ObjectTypeDefinition(obj) -> {
      let assert 1 = list.length(obj.fields)
    }
    _ -> panic as "Expected ObjectTypeDefinition"
  }
}

pub fn orphan_extension_becomes_base_type_test() {
  let doc = merge(["extend type Mutation { doThing: String }"])
  let _td = find_type(doc, "Mutation")
  Nil
}

pub fn extend_union_merges_members_test() {
  let doc =
    merge([
      "union SearchResult = User | Post",
      "extend union SearchResult = Video",
    ])
  case find_type(doc, "SearchResult") {
    sdl_ast.UnionTypeDefinition(u) -> {
      let assert 3 = list.length(u.member_types)
    }
    _ -> panic as "Expected UnionTypeDefinition"
  }
}

pub fn multiple_orphan_extensions_merge_into_one_type_test() {
  let doc =
    merge([
      "extend type Mutation { doThing: String }",
      "extend type Mutation { doOther: Int }",
    ])
  case find_type(doc, "Mutation") {
    sdl_ast.ObjectTypeDefinition(obj) -> {
      let assert 2 = list.length(obj.fields)
    }
    _ -> panic as "Expected ObjectTypeDefinition"
  }
}

pub fn extend_interface_merges_fields_test() {
  let doc =
    merge([
      "interface Node { id: ID! }",
      "extend interface Node { createdAt: String }",
    ])
  case find_type(doc, "Node") {
    sdl_ast.InterfaceTypeDefinition(iface) -> {
      let assert 2 = list.length(iface.fields)
    }
    _ -> panic as "Expected InterfaceTypeDefinition"
  }
}

pub fn extend_input_merges_fields_test() {
  let doc =
    merge([
      "input CreateUserInput { name: String! }",
      "extend input CreateUserInput { email: String }",
    ])
  case find_type(doc, "CreateUserInput") {
    sdl_ast.InputObjectTypeDefinition(input) -> {
      let assert 2 = list.length(input.fields)
    }
    _ -> panic as "Expected InputObjectTypeDefinition"
  }
}

pub fn extend_union_directives_only_test() {
  let doc =
    merge([
      "union SearchResult = User | Post",
      "extend union SearchResult @deprecated",
    ])
  case find_type(doc, "SearchResult") {
    sdl_ast.UnionTypeDefinition(u) -> {
      let assert 2 = list.length(u.member_types)
      let assert 1 = list.length(u.directives)
    }
    _ -> panic as "Expected UnionTypeDefinition"
  }
}

pub fn extend_enum_merges_values_test() {
  let doc =
    merge([
      "enum Status { ACTIVE INACTIVE }",
      "extend enum Status { PENDING }",
    ])
  case find_type(doc, "Status") {
    sdl_ast.EnumTypeDefinition(e) -> {
      let assert 3 = list.length(e.values)
    }
    _ -> panic as "Expected EnumTypeDefinition"
  }
}
