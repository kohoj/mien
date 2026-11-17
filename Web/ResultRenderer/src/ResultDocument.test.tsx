import { describe, expect, test } from "bun:test";
import React from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { ResultDocument } from "./ResultDocument";

describe("Mien result document", () => {
  test("renders Markdown and CJK-adjacent emphasis instead of showing markup", () => {
    const html = renderToStaticMarkup(
      <ResultDocument markdown="从列表看，**Claude Opus 5** 最强；**GPT 5.6 Sol** 也很稳。" />,
    );

    expect(html).toContain('data-streamdown="strong"');
    expect(html).not.toContain("**Claude Opus 5**");
    expect(html).not.toContain("**GPT 5.6 Sol**");
    expect(html.match(/data-streamdown="strong"/g)).toHaveLength(2);
  });

  test("drops raw HTML and network images", () => {
    const html = renderToStaticMarkup(
      <ResultDocument markdown={"<script>window.compromised = true</script>\n\n![tracking](https://example.com/pixel.png)"} />,
    );

    expect(html).not.toContain("script");
    expect(html).not.toContain("img");
    expect(html).not.toContain("example.com");
  });

  test("keeps safe links for the native navigation delegate", () => {
    const html = renderToStaticMarkup(
      <ResultDocument markdown="[官方文档](https://example.com/docs) [危险链接](javascript:alert(1))" />,
    );

    expect(html).toContain('href="https://example.com/docs"');
    expect(html).not.toContain("javascript:");
  });

  test("renders the core document structures used by Agent answers", () => {
    const html = renderToStaticMarkup(
      <ResultDocument
        markdown={"## 结论\n\n- 第一项\n- 第二项\n\n| 模型 | 状态 |\n| --- | --- |\n| Sol | 稳定 |\n\n```swift\nlet ready = true\n```"}
      />,
    );

    expect(html).toContain('data-streamdown="heading-2"');
    expect(html).toContain('data-streamdown="unordered-list"');
    expect(html).toContain('data-streamdown="table"');
    expect(html).toContain("let ready = true");
  });
});
