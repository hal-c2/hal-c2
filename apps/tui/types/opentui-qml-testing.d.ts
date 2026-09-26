// See opentui-qml.d.ts: the slice of `opentui-qml/testing` the TUI uses.
import type { CapturedFrame } from "@opentui/core";
import type { KeyInput } from "@opentui/core/testing";
import type { QmlApp, QmlEngine, QmlObject, RunQmlOptions } from "opentui-qml";

export interface KeyModifiers {
  shift?: boolean;
  ctrl?: boolean;
  meta?: boolean;
  super?: boolean;
  hyper?: boolean;
}

export interface TestQmlOptions extends Omit<RunQmlOptions, "renderer" | "rendererConfig"> {
  width?: number;
  height?: number;
  filename?: string;
  render?: boolean;
}

export interface QmlTestApp {
  app: QmlApp;
  engine: QmlEngine;
  root: QmlObject;
  proxy: any;
  renderer: QmlApp["renderer"];
  setup: { captureSpans(): CapturedFrame };
  warnings: string[];
  errors: unknown[];
  renderOnce(): Promise<void>;
  captureCharFrame(): string;
  snapshot(): Promise<string>;
  pressKey(key: KeyInput, modifiers?: KeyModifiers): Promise<void>;
  typeText(text: string): Promise<void>;
  pressEnter(modifiers?: KeyModifiers): Promise<void>;
  pressEscape(modifiers?: KeyModifiers): Promise<void>;
  pressTab(modifiers?: KeyModifiers): Promise<void>;
  pressArrow(direction: "up" | "down" | "left" | "right", modifiers?: KeyModifiers): Promise<void>;
  paste(text: string): Promise<void>;
  click(x: number, y: number): Promise<void>;
  resize(width: number, height: number): Promise<void>;
  advance(ms: number): Promise<void>;
  destroy(): void;
}

export function testQml(
  source: string | { file: string },
  options?: TestQmlOptions,
): Promise<QmlTestApp>;
