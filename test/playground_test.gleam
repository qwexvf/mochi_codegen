import gleam/string
import gleeunit/should
import mochi_codegen/playground

pub fn graphiql_escapes_single_quote_test() {
  let html = playground.graphiql("http://api.test/'; alert('xss'); //")

  // Endpoint-break via bare single-quote must be gone.
  html
  |> string.contains("url: 'http://api.test/'; alert('xss'); //',")
  |> should.be_false

  // Escaped form is present.
  html |> string.contains("\\'") |> should.be_true
}

pub fn graphiql_escapes_script_close_test() {
  let html = playground.graphiql("http://api.test/</script><script>evil()")

  // Bare </script> inside the endpoint literal must not appear — it'd close
  // the surrounding <script> tag.
  let inner = case string.split(html, "const fetcher") {
    [_, after, ..] -> after
    _ -> ""
  }
  inner |> string.contains("</script><script>") |> should.be_false
  inner |> string.contains("<\\/script>") |> should.be_true
}

pub fn simple_explorer_escapes_html_endpoint_test() {
  let html =
    playground.simple_explorer("http://api.test/<script>bad()</script>")

  // Endpoint is rendered in two places — HTML text and JS literal.
  // Raw `<script>` must not appear in the HTML-text site.
  html
  |> string.contains("id=\"endpoint\">http://api.test/<script>")
  |> should.be_false
  html |> string.contains("&lt;script&gt;") |> should.be_true
}

pub fn apollo_sandbox_escapes_endpoint_test() {
  let html = playground.apollo_sandbox("http://api.test/'; x=1")

  html
  |> string.contains("initialEndpoint: 'http://api.test/'; x=1',")
  |> should.be_false
  html |> string.contains("\\'") |> should.be_true
}
