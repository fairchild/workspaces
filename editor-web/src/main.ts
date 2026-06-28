// Embedded diff/editor surface hosted in the WorkspaceManager app's WKWebView.
//
// Swift drives this through `window.__editorHost` (init/getDoc/setTheme/reload/markSaved);
// the editor reports back over `window.webkit.messageHandlers.editor` (ready/dirty/save/log).
// `review` mode renders an editable unified diff against HEAD with per-hunk accept/reject;
// `edit` mode is a plain editor. Either way the saved artifact is the current document text.

import { Compartment, EditorState } from "@codemirror/state"
import { EditorView, keymap } from "@codemirror/view"
import { basicSetup } from "codemirror"
import { indentWithTab } from "@codemirror/commands"
import { LanguageSupport, StreamLanguage } from "@codemirror/language"
import { unifiedMergeView } from "@codemirror/merge"
import { javascript } from "@codemirror/lang-javascript"
import { python } from "@codemirror/lang-python"
import { json } from "@codemirror/lang-json"
import { markdown } from "@codemirror/lang-markdown"
import { swift as swiftMode } from "@codemirror/legacy-modes/mode/swift"
import { shell as shellMode } from "@codemirror/legacy-modes/mode/shell"

type Mode = "review" | "edit"

interface InitPayload {
  mode: Mode
  head: string
  working: string
  language: string
  theme: "light" | "dark"
  fontFamily: string
  fontSize: number
}

interface ThemePayload {
  theme: "light" | "dark"
  fontFamily: string
  fontSize: number
}

declare global {
  interface Window {
    __editorHost: {
      init(payload: InitPayload): void
      reload(payload: InitPayload): void
      getDoc(): string
      setTheme(payload: ThemePayload): void
      markSaved(): void
    }
    webkit?: {
      messageHandlers?: {
        editor?: { postMessage(message: unknown): void }
      }
    }
  }
}

function post(message: Record<string, unknown>): void {
  window.webkit?.messageHandlers?.editor?.postMessage(message)
}

function languageExtension(language: string): LanguageSupport | [] {
  switch (language) {
    case "javascript":
    case "typescript":
      return javascript({ typescript: language === "typescript", jsx: true })
    case "python":
      return python()
    case "json":
      return json()
    case "markdown":
      return markdown()
    case "swift":
      return new LanguageSupport(StreamLanguage.define(swiftMode))
    case "shell":
      return new LanguageSupport(StreamLanguage.define(shellMode))
    default:
      return []
  }
}

function makeTheme(payload: ThemePayload) {
  const dark = payload.theme === "dark"
  const bg = dark ? "#1e1e1e" : "#ffffff"
  const fg = dark ? "#d4d4d4" : "#1d1d1f"
  const gutterBg = dark ? "#1e1e1e" : "#fbfbfd"
  const gutterFg = dark ? "#6e7681" : "#a0a0a8"
  const selection = dark ? "#2d4f67" : "#b3d7ff"
  document.documentElement.style.setProperty("--editor-bg", bg)
  return EditorView.theme(
    {
      "&": { color: fg, backgroundColor: bg, height: "100%" },
      ".cm-content": {
        fontFamily: payload.fontFamily,
        fontSize: `${payload.fontSize}px`,
        caretColor: fg,
      },
      ".cm-gutters": { backgroundColor: gutterBg, color: gutterFg, border: "none" },
      ".cm-activeLine": { backgroundColor: dark ? "#ffffff0a" : "#00000008" },
      ".cm-activeLineGutter": { backgroundColor: dark ? "#ffffff12" : "#0000000d" },
      "&.cm-focused .cm-selectionBackground, .cm-selectionBackground, ::selection": {
        backgroundColor: selection,
      },
    },
    { dark }
  )
}

const themeCompartment = new Compartment()

let view: EditorView | null = null
let baseline = ""
let lastDirty = false
let currentTheme: ThemePayload = {
  theme: "light",
  fontFamily: "ui-monospace, SFMono-Regular, Menlo, monospace",
  fontSize: 12,
}

function emitDirty(): void {
  if (!view) return
  const dirty = view.state.doc.toString() !== baseline
  if (dirty !== lastDirty) {
    lastDirty = dirty
    post({ type: "dirty", value: dirty })
  }
}

const dirtyListener = EditorView.updateListener.of((update) => {
  if (update.docChanged) emitDirty()
})

const saveKeymap = keymap.of([
  {
    key: "Mod-s",
    run: () => {
      post({ type: "save" })
      return true
    },
  },
])

function build(payload: InitPayload): void {
  currentTheme = {
    theme: payload.theme,
    fontFamily: payload.fontFamily,
    fontSize: payload.fontSize,
  }
  baseline = payload.working
  lastDirty = false

  const extensions = [
    basicSetup,
    keymap.of([indentWithTab]),
    saveKeymap,
    dirtyListener,
    languageExtension(payload.language),
    themeCompartment.of(makeTheme(currentTheme)),
  ]

  if (payload.mode === "review") {
    // Original = HEAD (read-only side); the editable doc is the working tree.
    // Per-hunk controls let a reviewer accept (keep) or reject (revert to HEAD).
    extensions.push(
      unifiedMergeView({
        original: payload.head,
        mergeControls: true,
        gutter: true,
      })
    )
  }

  view?.destroy()
  const root = document.getElementById("root")!
  root.innerHTML = ""
  view = new EditorView({
    parent: root,
    state: EditorState.create({ doc: payload.working, extensions }),
  })
  view.focus()
}

window.__editorHost = {
  init(payload) {
    build(payload)
  },
  reload(payload) {
    build(payload)
  },
  getDoc() {
    return view?.state.doc.toString() ?? ""
  },
  setTheme(payload) {
    currentTheme = payload
    view?.dispatch({
      effects: themeCompartment.reconfigure(makeTheme(payload)),
    })
  },
  markSaved() {
    if (!view) return
    baseline = view.state.doc.toString()
    if (lastDirty) {
      lastDirty = false
      post({ type: "dirty", value: false })
    }
  },
}

post({ type: "ready" })
