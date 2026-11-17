import React from "react";
import { createRoot } from "react-dom/client";
import { ResultDocument } from "./ResultDocument";

type Theme = {
  label: string;
  background: string;
  colorScheme: "light" | "dark";
  secondaryLabel: string;
  tertiaryLabel: string;
  separator: string;
  link: string;
  codeBackground: string;
  selection: string;
  fontSize: number;
};

type RendererState = {
  markdown: string;
  theme: Theme;
};

declare global {
  interface Window {
    mien: {
      render(markdown: string, theme: Theme): void;
    };
    webkit?: {
      messageHandlers?: {
        mienRenderer?: {
          postMessage(message: { type: "height"; height: number }): void;
        };
      };
    };
  }
}

const rootElement = document.getElementById("root");
if (!rootElement) {
  throw new Error("Mien result renderer is missing its root element");
}

const root = createRoot(rootElement);
let state: RendererState | null = null;

function applyTheme(theme: Theme): void {
  const style = document.documentElement.style;
  style.setProperty("--mien-label", theme.label);
  style.setProperty("--mien-background", theme.background);
  style.colorScheme = theme.colorScheme;
  style.setProperty("--mien-secondary-label", theme.secondaryLabel);
  style.setProperty("--mien-tertiary-label", theme.tertiaryLabel);
  style.setProperty("--mien-separator", theme.separator);
  style.setProperty("--mien-link", theme.link);
  style.setProperty("--mien-code-background", theme.codeBackground);
  style.setProperty("--mien-selection", theme.selection);
  style.setProperty("--mien-font-size", `${theme.fontSize / 16}rem`);
}

function render(): void {
  if (!state) return;
  applyTheme(state.theme);
  root.render(<ResultDocument markdown={state.markdown} />);
}

window.mien = {
  render(markdown: string, theme: Theme): void {
    state = { markdown, theme };
    render();
  },
};

let previousHeight = -1;
const resizeObserver = new ResizeObserver(() => {
  const height = Math.ceil(rootElement.getBoundingClientRect().height);
  if (height === previousHeight) return;
  previousHeight = height;
  window.webkit?.messageHandlers?.mienRenderer?.postMessage({ type: "height", height });
});
resizeObserver.observe(rootElement);
