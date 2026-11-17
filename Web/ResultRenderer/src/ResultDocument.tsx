import { cjk } from "@streamdown/cjk";
import React from "react";
import { Streamdown } from "streamdown";

const allowedElements = [
  "a",
  "blockquote",
  "br",
  "code",
  "del",
  "em",
  "h1",
  "h2",
  "h3",
  "h4",
  "h5",
  "h6",
  "hr",
  "img",
  "li",
  "ol",
  "p",
  "pre",
  "section",
  "strong",
  "sub",
  "sup",
  "table",
  "tbody",
  "td",
  "th",
  "thead",
  "tr",
  "ul",
];

function safeURL(url: string, key: string): string | null {
  if (key === "src") return null;
  try {
    const parsed = new URL(url);
    return parsed.protocol === "https:" || parsed.protocol === "mailto:" ? parsed.href : null;
  } catch {
    return null;
  }
}

export function ResultDocument({ markdown }: { markdown: string }) {
  return (
    <Streamdown
      className="mien-result"
      mode="static"
      parseIncompleteMarkdown={false}
      plugins={{ cjk }}
      controls={false}
      linkSafety={{ enabled: false }}
      skipHtml
      urlTransform={safeURL}
      allowedElements={allowedElements}
      components={{
        img: ({ alt }) =>
          alt ? <span className="mien-image-alt">{alt}</span> : null,
      }}
    >
      {markdown}
    </Streamdown>
  );
}
