import { basicSetup } from "codemirror";
import { EditorState } from "@codemirror/state";
import { EditorView, keymap } from "@codemirror/view";
import { indentWithTab } from "@codemirror/commands";
import { syntaxHighlighting, HighlightStyle } from "@codemirror/language";
import { tags } from "@lezer/highlight";
import { elixir } from "codemirror-lang-elixir";

const field = document.getElementById("source");
const mount = document.getElementById("code-editor");

if (field && mount) {
  const palette = EditorView.theme({
    "&": { backgroundColor: "#222235", color: "#f0eefb", fontSize: "13px" },
    ".cm-content": { padding: "15px 0", caretColor: "#d2afff", fontFamily: "ui-monospace, SFMono-Regular, Menlo, Monaco, monospace" },
    ".cm-scroller": { fontFamily: "ui-monospace, SFMono-Regular, Menlo, Monaco, monospace", lineHeight: "1.65" },
    ".cm-gutters": { backgroundColor: "#1c1c2e", color: "#a9a6bd", borderRight: "1px solid #45415c" },
    ".cm-activeLine": { backgroundColor: "#302e47" },
    ".cm-activeLineGutter": { backgroundColor: "#302e47", color: "#e6dbff" },
    ".cm-selectionBackground, &.cm-focused .cm-selectionBackground": { backgroundColor: "#634a99aa" },
    ".cm-cursor, .cm-dropCursor": { borderLeftColor: "#d2afff" },
    ".cm-panels": { backgroundColor: "#29283e", color: "#f0eefb" },
    ".cm-panels input": { backgroundColor: "#1c1c2e", color: "#f0eefb", border: "1px solid #69618a" },
    ".cm-matchingBracket": { backgroundColor: "#4d3d73", outline: "1px solid #a48bd0" }
  }, { dark: true });

  const colors = HighlightStyle.define([
    { tag: tags.keyword, color: "#c8a8ff" },
    { tag: tags.string, color: "#a8dfc1" },
    { tag: tags.number, color: "#f2c993" },
    { tag: tags.comment, color: "#a8a5b9", fontStyle: "italic" },
    { tag: tags.operator, color: "#cfb2ef" },
    { tag: tags.typeName, color: "#85d0dd" },
    { tag: tags.function(tags.variableName), color: "#bdd8ff" },
    { tag: tags.propertyName, color: "#f0d4a6" }
  ]);

  const editor = new EditorView({
    state: EditorState.create({
      doc: field.value,
      extensions: [
        basicSetup,
        elixir(),
        palette,
        syntaxHighlighting(colors),
        EditorState.tabSize.of(2),
        keymap.of([indentWithTab]),
        EditorView.cspNonce.of(mount.dataset.styleNonce),
        EditorView.contentAttributes.of({ "aria-label": "Elixir source", "aria-describedby": "editor-note" }),
        EditorView.updateListener.of((update) => {
          if (update.docChanged) field.value = update.state.doc.toString();
        })
      ]
    }),
    parent: mount
  });

  mount.hidden = false;
  field.classList.add("editor-fallback-hidden");
  field.required = false;
  document.querySelector("label[for='source']")?.addEventListener("click", () => editor.focus());
  field.form?.addEventListener("submit", (event) => {
    field.value = editor.state.doc.toString();
    if (field.value.length === 0) {
      event.preventDefault();
      editor.focus();
    }
  });
}
