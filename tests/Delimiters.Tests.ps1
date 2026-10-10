$here = Split-Path -Parent $MyInvocation.MyCommand.Path
Import-Module (Join-Path $here '..\lib\Lint.psm1') -Force
Import-Module (Join-Path $here '..\lib\AutoFix.psm1') -Force
Import-Module (Join-Path $here '..\lib\CheckPolicy.psm1') -Force

Describe 'Each language has its own opening and closing delimiters' {
    It 'PHP: <?php needs ?> before the next <?php, a stray ?> is reported, the last block may run to the end' {
        @(Test-Delimiters 'page.php' "<?php `$a = 1; ?>`n<p><?= `$a ?></p>`n<?php if (`$a) { echo '?>'; }`n").Count | Should Be 0
        @(Test-Delimiters 'page.php' "<?php `$a = 1;`n<p>x</p>`n<?php echo 2; ?>")[0] | Should Be 'line 1: <?php is never closed with ?> (the next <?php starts at line 3)'
        @(Test-Delimiters 'page.php' "<p>x</p> ?>")[0] | Should Be 'line 1: ?> closes nothing (no <?php before it)'
    }
    It 'Blade: @if needs @endif, @section(name) needs @endsection, {{ }} and {!! !!} pair' {
        $ok = "@extends('layout')`n@section('title', 'Home')`n@section('content')`n@if (`$x)`n  <p>{{ `$x }}</p>`n@elseif (`$y)`n  @foreach (`$items as `$i) <li>{{ `$i }}</li> @endforeach`n@else`n  {!! `$raw !!}`n@endif`n@endsection`n@push('scripts') <script src=""a.js""></script> @endpush`n@forelse (`$u as `$v) x @empty none @endforelse`n@php `$z = 1; @endphp"
        @(Test-Delimiters 'home.blade.php' $ok).Count | Should Be 0
        @(Test-Delimiters 'home.blade.php' "@if (`$x)`n<p>a</p>`n@foreach (`$l as `$i)`n{{ `$i }}`n@endif")[0] | Should Be "line 5: '@endif' arrives while the '@foreach' from line 3 is still open: that one needs '@endforeach' first"
        @(Test-Delimiters 'home.blade.php' "@section('content')`n<p>{{ `$x </p>")[0] | Should Be 'line 2: {{ is never closed with }}'
    }
    It 'EJS, ERB, JSP and ASP: <% needs %> before the next <%' {
        @(Test-Delimiters 'list.ejs' "<ul><% items.forEach(function (i) { %>`n<li><%= i %></li>`n<% }); %></ul> <%%literal").Count | Should Be 0
        @(Test-Delimiters 'list.ejs' "<ul><% items.forEach(function (i) {`n<li><%= i %></li>")[0] | Should Be 'line 1: <% is never closed with %> (the next <% starts at line 2)'
        @(Test-Delimiters 'show.erb' "<% if @x %>`n<p><%= @x %></p>`n<% end -%>").Count | Should Be 0
        @(Test-Delimiters 'index.jsp' "<%@ page language=""java"" %>`n<%-- a %> in a comment --%>`n<% out.println(""%>""); %>").Count | Should Be 0
    }
    It 'Jinja, Twig, Nunjucks, Liquid and Django: {% X %} needs {% endX %}, {% %} and {{ }} pair' {
        $ok = "{% extends ""base.html"" %}`n{# a {% comment #}`n{% block content %}`n{% for i in items %}`n  {% if i.ok %}<li>{{ i.name }}</li>{% elif i.x %}x{% else %}y{% endif %}`n{% endfor %}`n{% set a = 1 %}`n{% set b %}text{% endset %}`n{% raw %}{% if %}{% endraw %}`n{% endblock content %}"
        @(Test-Delimiters 'page.njk' $ok).Count | Should Be 0
        @(Test-Delimiters 'page.twig' "{% for i in items %}`n{% if i %}`n<li>{{ i }}</li>`n{% endfor %}")[0] | Should Be "line 4: '{% endfor %}' arrives while the '{% if %}' from line 2 is still open: that one needs '{% endif %}' first"
        @(Test-Delimiters 'page.liquid' "{% for i in items %}`n{{ i }}`n{% endfor %}`n{% capture x %}y")[0] | Should Be "line 4: '{% capture %}' is never closed with '{% endcapture %}'"
        @(Test-Delimiters 'page.j2' "<p>{{ name </p>`n{% if a %}")[0] | Should Be 'line 1: {{ is never closed with }}'
        @(Test-Delimiters 'page.html' "<html><body>{% for i in items %}<li>{{ i }}</li>{% endfor %}{% if x %}</body></html>")[0] | Should Be "line 1: '{% if %}' is never closed with '{% endif %}'"
    }
    It 'Handlebars and Mustache: {{#x}} needs {{/x}}, {{ }} pairs, comments and raw blocks are skipped' {
        $ok = "{{!-- {{#if}} in a comment --}}`n{{#if user}}<p>{{user.name}}</p>{{else}}<p>none</p>{{/if}}`n{{#each items as |i|}}{{{i.html}}}{{/each}}`n{{^missing}}x{{/missing}}`n{{> partial}}`n{{#> layout}}body{{/layout}}"
        @(Test-Delimiters 'page.hbs' $ok).Count | Should Be 0
        @(Test-Delimiters 'page.hbs' "{{#if a}}`n{{#each b}}`n<li>{{this}}</li>`n{{/if}}")[0] | Should Be "line 4: '{{/if}}' arrives while the '{{#each}}' from line 2 is still open: that one needs '{{/each}}' first"
        @(Test-Delimiters 'page.mustache' "{{#items}}<li>{{name}</li>{{/items}}")[0] | Should Be 'line 1: {{ is never closed with }} (the next {{ starts at line 1)'
        @(Test-Delimiters 'page.html' "<ul>{{#each items}}<li>{{name}}</li>{{/each}}{{#if x}}</ul>")[0] | Should Be "line 1: '{{#if}}' is never closed with '{{/if}}'"
    }
    It 'Go templates: {{if}}, {{range}}, {{with}}, {{define}} and {{block}} need {{end}}' {
        @(Test-Delimiters 'page.gohtml' "{{define ""main""}}{{/* {{if}} */}}{{range .Items}}{{if .Ok}}<li>{{.Name}}</li>{{else}}x{{end}}{{end}}{{end}}").Count | Should Be 0
        @(Test-Delimiters 'page.tmpl' "{{range .Items}}`n{{if .Ok}}<li>{{.Name}}</li>`n{{end}}")[0] | Should Be "line 1: '{{range}}' is never closed with '{{end}}'"
    }
    It 'Smarty: {if} needs {/if}' {
        @(Test-Delimiters 'page.tpl' "{* {if} *}{if `$a}{foreach `$items as `$i}<li>{`$i}</li>{/foreach}{else}x{/if}{literal}{if}{/literal}").Count | Should Be 0
        @(Test-Delimiters 'page.tpl' "{if `$a}`n{foreach `$items as `$i}<li>{`$i}</li>`n{/if}")[0] | Should Be "line 3: '{/if}' arrives while the '{foreach}' from line 2 is still open: that one needs '{/foreach}' first"
    }
    It 'Svelte: {#if} needs {/if}, and the tags must balance' {
        $ok = "<script>`n  let a = 1; if (a <b) { x(); }`n</script>`n{#if a}`n  <p class=""x"">{a < 3 ? 'y' : 'z'}</p>`n{:else}`n  {#each items as {id, name} (id)}<li>{name}</li>{/each}`n{/if}`n<svelte:window on:resize={fn} />"
        @(Test-Delimiters 'App.svelte' $ok).Count | Should Be 0
        @(Test-Delimiters 'App.svelte' "{#if a}`n{#each items as i}`n<li>{i}</li>`n{/if}")[0] | Should Be "line 4: '{/if}' arrives while the '{#each}' from line 2 is still open: that one needs '{/each}' first"
        @(Test-Delimiters 'App.svelte' "{#if a}`n<div class=""x"">`n<p>t</p>`n{/if}")[0] | Should Be 'line 2: <div> is never closed'
    }
    It 'Vue: {{ }} pairs and the template tags balance (script and style are left alone)' {
        $ok = "<template>`n  <div :class=""{ a: b > 1 }"" @click=""go"">{{ title }}<MyComp v-if=""x"" />`n    <template #footer><span>{{ fn({ a: 1 }) }}</span></template>`n  </div>`n</template>`n<script setup lang=""ts"">`nconst m: Map<string, number> = new Map(); if (a <b) { x(); }`n</script>`n<style scoped>.a { color: red }</style>"
        @(Test-Delimiters 'App.vue' $ok).Count | Should Be 0
        @(Test-Delimiters 'App.vue' "<template>`n  <div>{{ title </div>`n</template>")[0] | Should Be 'line 2: {{ is never closed with }}'
        @(Test-Delimiters 'App.vue' "<template>`n  <div>`n  <p>{{ a }}</p>`n</template>")[0] | Should Be 'line 2: <div> is not closed before </template> at line 4'
    }
    It 'Astro: the frontmatter closes, fragments pair, tags balance' {
        $ok = "---`nconst items = await get(); const a = b <c;`n---`n<ul>{items.map((i) => <li class=""x"">{i.name}</li>)}</ul>`n{cond && <><p>a</p><p>b</p></>}"
        @(Test-Delimiters 'index.astro' $ok).Count | Should Be 0
        @(Test-Delimiters 'index.astro' "---`nconst a = 1;`n<p>x</p>")[0] | Should Be 'line 1: the --- frontmatter is never closed with a --- line'
        @(Test-Delimiters 'index.astro' "---`nconst a = 1;`n---`n<div><>{a}</div>")[0] | Should Be 'line 4: the <> fragment is never closed with </>'
    }
    It 'JSX/TSX: <> fragments pair, a tag that lost its > before a tag line is found and closed, generics are not tags' {
        @(Test-Delimiters 'App.tsx' "const m: Map<string, Array<number>> = new Map();`nexport const A = () => (<><p>a</p><p>b</p></>);`nconst s = ""<>"";").Count | Should Be 0
        @(Test-Delimiters 'App.tsx' "export const A = () => (`n  <>`n    <p>a</p>`n  );")[0] | Should Be 'line 2: the <> fragment is never closed with </>'
        $p = "export function A({ cls }) {`n  return (`n    <div className={cls}`n      <span>x</span>`n    </div>`n  );`n}"
        $f = @(Find-LeakedMarkup 'A.jsx' $p)
        $f[0].message | Should Be 'line 3: the tag <div className={cls} has no > (the next line starts a tag), so the file does not compile: close it with >'
        (Repair-MechanicalIssues 'A.jsx' $p).text | Should Match "(?m)^    <div className=\{cls\}>`n      <span>x</span>$"
        @(Find-LeakedMarkup 'A.tsx' "const m: Map<string,`n  Array<number>> = x;`nif (a <b) {`n  <p>t</p>`n}").Count | Should Be 0
    }
    It 'Razor: the braces of the code blocks must match (a warning)' {
        $ok = "@page`n@model X`n@{ var n = Model.Items.Count; var s = ""{"" + '{'; }`n@if (n > 0) {`n  <ul>@foreach (var i in Model.Items) { <li class=""x"">@i.Name</li> }</ul>`n} else {`n  <p>none (0)</p>`n}`n@code { int x = 1; string y = @""{""; }`n<script>if (a) { b(); }</script>`n@* { *@"
        @(Test-Delimiters 'Index.cshtml' $ok).Count | Should Be 0
        $r = @(Test-Delimiters 'Index.cshtml' "@if (x) {`n  <p>a</p>`n@foreach (var i in l) {`n  <li>@i</li>`n}")
        $r[0] | Should Be "line 1: '{' is never closed in the Razor code blocks: the braces of @{ }, @if, @foreach, @code and @functions must match"
        Get-CheckLevel $r[0] 'file' | Should Be 'warning'
    }
    It 'Angular: the braces of @if, @for and @switch blocks must match' {
        $ok = "<div [ngClass]=""{ a: x }"">`n@if (items.length > 0) {`n  <ul>@for (i of items; track i.id) { <li>{{ i.name }}</li> } @empty { <li>none</li> }</ul>`n} @else {`n  <p>{{ 'none' }}</p>`n}`n@switch (mode) { @case ('a') { <p>a</p> } @default { <p>d</p> } }`n</div>"
        @(Test-Delimiters 'app.component.html' $ok).Count | Should Be 0
        @(Test-Delimiters 'app.component.html' "@if (a) {`n  <p>x</p>`n@for (i of l; track i) {`n  <li>{{ i }}</li>`n}")[0] | Should Be "line 1: '{' is never closed in the Angular @if, @for, @switch and @defer blocks: their braces must match"
    }
    It 'Visual Basic: Sub, Function, If, For, Do, While, Select, With and Property blocks close by kind' {
        $ok = "Option Explicit`nPublic Sub Main()`n    Dim i As Integer`n    If i > 0 Then Debug.Print ""one-line""`n    If i = 0 Then ' comment`n        For i = 1 To 3`n            Do While i < 2 _`n                And i > -1`n                i = i + 1`n            Loop`n        Next i`n    ElseIf i = 2 Then`n        Set o = Nothing`n    Else`n        Select Case i`n            Case 1: Exit Sub`n            Case Else`n        End Select`n    End If`n    With o`n        .x = ""End Sub""`n    End With`n    While i < 9: i = i + 1: Wend`nEnd Sub`nPublic Property Get Name() As String`n    Name = ""x""`nEnd Property`nPrivate Declare PtrSafe Function GetTick Lib ""kernel32"" Alias ""GetTickCount"" () As Long"
        @(Test-Delimiters 'Module1.bas' $ok).Count | Should Be 0
        @(Test-Delimiters 'Module1.bas' "Sub A()`n    If x Then`n        For i = 1 To 2`n    End If`nEnd Sub")[0] | Should Be "line 4: 'End If' arrives while the 'For' from line 3 is still open: that one needs 'Next' first"
        @(Test-Delimiters 'script.vbs' "Function F(a)`n    If a Then`n        F = 1`nEnd Function")[0] | Should Be "line 4: 'End Function' arrives while the 'If' from line 2 is still open: that one needs 'End If' first"
        @(Test-Delimiters 'Form1.cls' "VERSION 1.0 CLASS`nBEGIN`n  MultiUse = -1`nEND`nAttribute VB_Name = ""Form1""`nPrivate Sub Go()`n    Do`n        x = 1`n")[0] | Should Be "line 7: 'Do' is never closed with 'Loop'"
        @(Test-Delimiters 'Thing.vb' "Public Class Thing`n    Public Property Name As String`n    Public Property Age As Integer`n        Get`n            Return 1`n        End Get`n        Set(value As Integer)`n        End Set`n    End Property`n    Public Sub Run()`n        Using r = New Reader()`n            Try`n            Catch ex As Exception`n            End Try`n        End Using`n    End Sub`nEnd Class").Count | Should Be 0
    }
    It 'Lua: function, if, do and repeat need end or until' {
        $ok = "local function f(a)`n  if a then return 1 elseif a == 2 then return 2 else return 3 end`n  for i = 1, 3 do print(i) end`n  while a do a = a - 1 end`n  repeat a = a + 1 until a > 5`n  local s = [[ end ]] .. ""end"" -- end`n  --[[ if`n  ]]`n  return t.end`nend"
        @(Test-Delimiters 'main.lua' $ok).Count | Should Be 0
        @(Test-Delimiters 'main.lua' "function f()`n  if a then`n    for i = 1, 2 do`n      print(i)`n  end`nend")[0] | Should Be "line 1: 'function' is never closed with 'end'"
        @(Test-Delimiters 'main.lua' "repeat`n  x()`nend")[0] | Should Be "line 3: 'end' arrives while the 'repeat' from line 1 is still open: that one needs 'until' first"
    }
    It 'Ruby: def, class, if and do blocks need end (a warning)' {
        $ok = "class Foo < Bar`n  def run(x)`n    return 1 if x.nil?`n    y = if x > 1 then 2 else 3 end`n    x.each do |i|`n      puts i unless i.end`n    end`n    while x > 0 do x -= 1 end`n    begin`n      raise 'end'`n    rescue => e`n      puts <<~EOS`n        end`n      EOS`n    end`n  end`n  def short = 1 # end`nend"
        @(Test-Delimiters 'foo.rb' $ok).Count | Should Be 0
        $r = @(Test-Delimiters 'foo.rb' "def a`n  if x`n    puts 1`nend")
        $r[0] | Should Be "line 1: 'def' is never closed with 'end' (Ruby blocks)"
        Get-CheckLevel $r[0] 'file' | Should Be 'warning'
    }
    It 'LaTeX: \begin{x} needs \end{x}, braces match' {
        @(Test-Delimiters 'paper.tex' "\documentclass{article} % \begin{x}`n\begin{document}`n\begin{itemize}\item a \verb|}| \end{itemize}`n\begin{verbatim}\end{document}\end{verbatim}`n\[ x \] \{ y`n\end{document}").Count | Should Be 0
        @(Test-Delimiters 'paper.tex' "\begin{document}`n\begin{itemize}`n\item a`n\end{enumerate}")[0] | Should Be "line 4: '\end{enumerate}' arrives while the '\begin{itemize}' from line 2 is still open: that one needs '\end{itemize}' first"
        @(Test-Delimiters 'paper.tex' "\section{Intro`n\end{x}")[0] | Should Be "line 2: '\end{x}' closes nothing (no open block before it)"
    }
    It 'Makefile: ifeq needs endif, define needs endef' {
        @(Test-Delimiters 'Makefile' "ifeq (`$(OS),Windows_NT)`n  X = 1 # endif`nelse`n  X = 2`nendif`ndefine M`n  echo hi`nendef`nall:`n`tif [ -f x ]; then echo y; fi").Count | Should Be 0
        @(Test-Delimiters 'rules.mk' "ifdef DEBUG`nCFLAGS += -g`ndefine M`nendif")[0] | Should Be "line 4: 'endif' arrives while the 'define' from line 3 is still open: that one needs 'endef' first"
    }
    It 'CMake: if() needs endif(), foreach() needs endforeach()' {
        @(Test-Delimiters 'CMakeLists.txt' "if(WIN32)`n  foreach(f IN LISTS files) # endif()`n    message(""if()"")`n  endforeach()`nelseif(APPLE)`nelse()`nendif()`nfunction(f)`nendfunction()").Count | Should Be 0
        @(Test-Delimiters 'CMakeLists.txt' "if(WIN32)`n  foreach(f IN LISTS files)`n  endif()")[0] | Should Be "line 3: 'endif(' arrives while the 'foreach()' from line 2 is still open: that one needs 'endforeach()' first"
    }
    It 'Terraform: braces match, heredocs and strings are skipped' {
        @(Test-Delimiters 'main.tf' "resource ""x"" ""y"" {`n  a = ""{""`n  b = <<-EOT`n    {`n  EOT`n  # }`n}").Count | Should Be 0
        @(Test-Delimiters 'main.tf' "resource ""x"" ""y"" {`n  a = 1`n")[0] | Should Be "line 1: '{' is never closed"
    }
    It 'runs inside Test-FileContent' {
        @(Test-FileContent 'App.vue' "<template>`n  <div>{{ a </div>`n</template>") -join ';' | Should Match '\{\{ is never closed with \}\}'
        @(Test-FileContent 'page.php' "<?php echo 1;`n<p>a</p>`n<?php echo 2; ?>") -join ';' | Should Match '<\?php is never closed'
        @(Test-FileContent 'Module1.bas' "Sub A()`n  x = 1`nEnd Sub`n").Count | Should Be 0
    }
}
