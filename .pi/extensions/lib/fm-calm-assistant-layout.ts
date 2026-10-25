// Verified against Pi 0.81.1 and 0.82.0, which export AssistantMessageComponent with an
// updateContent method. installCalmAssistantLayout() probes that exact method and throws
// if it is missing; fm-calm.ts catches that and skips only this adapter with a diagnostic
// instead of blocking Calm or Pi.
// This layout removes thinking and reasoning blocks, collapsed or expanded, and short
// mid-turn assistant text blocks classified as "assistant-working-note" from a shallow
// presentation copy. Substantive mid-turn text is preserved. The message itself, model
// context, session storage, and export rendering are never touched.
// ./fm-calm-visibility.ts owns which classes Calm hides.
import type { AssistantMessageComponent as PiAssistantMessageComponent } from "@earendil-works/pi-coding-agent";
import * as PiCodingAgent from "@earendil-works/pi-coding-agent";
import { calmTextIsSubstantive } from "./fm-calm-preservation.ts";
import { calmPresentationHides } from "./fm-calm-visibility.ts";

type AssistantMessage = Parameters<PiAssistantMessageComponent["updateContent"]>[0];

type AssistantMessagePresentationState = {
  hiddenThinkingLabel: string;
  hideThinkingBlock: boolean;
  lastMessage?: AssistantMessage;
};

// Keep the introduction-version symbol stable so a second load updates the same
// wrapper. A live session that already installed the older wrapper keeps it as the
// inner call on the next load. This wrapper strips thinking before that inner call
// runs, so the older layer's collapsed-thinking gating no longer decides what shows.
const CALM_ASSISTANT_LAYOUT_PATCH = Symbol.for(
  "firstmate:calm-assistant-layout:pi-0.81.1",
);
const CALM_ASSISTANT_LAYOUT_GENERATION = 2;

type CalmAssistantLayoutPatch = {
  hidesThinking: () => boolean;
  hidesWorkingNote: () => boolean;
  // Absent on the wrapper that also required Pi's collapsed-thinking setting.
  // The next install wraps that wrapper rather than replacing it, so it stays in
  // the chain as the inner call.
  generation: typeof CALM_ASSISTANT_LAYOUT_GENERATION;
};

// A mid-turn assistant message is one the model did not end its response with: Pi's
// agent loop runs its tool calls and then issues another assistant message. stopReason
// is intrinsic to each message and is already set while the message streams, so this
// layout never has to ask whether the turn ended. It stays "pending" until the tool
// call materializes, which is why a working note is briefly visible before it
// collapses; suppressing pending text would also stop a genuine reply from streaming.
function isMidTurnAssistantMessage(message: AssistantMessage): boolean {
  if (message.stopReason === "toolUse") return true;
  return (
    message.stopReason === "length" &&
    message.content.some((block) => block.type === "toolCall")
  );
}

export function installCalmAssistantLayout(): void {
  const registry = globalThis as typeof globalThis & {
    [key: symbol]: CalmAssistantLayoutPatch | undefined;
  };
  const hidesThinking = (): boolean => calmPresentationHides("assistant-thinking");
  const hidesWorkingNote = (): boolean => calmPresentationHides("assistant-working-note");
  const installed = registry[CALM_ASSISTANT_LAYOUT_PATCH];
  if (installed?.generation === CALM_ASSISTANT_LAYOUT_GENERATION) {
    installed.hidesThinking = hidesThinking;
    installed.hidesWorkingNote = hidesWorkingNote;
    return;
  }

  const AssistantMessageComponent = PiCodingAgent.AssistantMessageComponent;
  if (typeof AssistantMessageComponent !== "function") {
    throw new Error("Firstmate Calm requires Pi AssistantMessageComponent");
  }
  const currentUpdateContent = AssistantMessageComponent.prototype.updateContent;
  if (typeof currentUpdateContent !== "function") {
    throw new Error("Firstmate Calm requires Pi AssistantMessageComponent.updateContent");
  }
  const patch: CalmAssistantLayoutPatch = {
    hidesThinking,
    hidesWorkingNote,
    generation: CALM_ASSISTANT_LAYOUT_GENERATION,
  };

  AssistantMessageComponent.prototype.updateContent = function (
    message: AssistantMessage,
    isStreaming?: boolean,
  ): void {
    const state = this as unknown as AssistantMessagePresentationState;
    // Expanded reasoning and per-block click expansion both re-enter this method.
    // Calm hides the thinking block itself, so those paths cannot put it back on screen.
    // Pi's hideThinkingBlock setting is not required: a collapsed "Thinking..." label
    // is still thinking chrome, and a session that never applied that setting still
    // paints the reasoning text.
    const hideThinking = patch.hidesThinking();
    const hideWorkingNote =
      patch.hidesWorkingNote() &&
      isMidTurnAssistantMessage(message) &&
      message.content.some(
        (block) => block.type === "text" && !calmTextIsSubstantive(block.text),
      );
    const presentationMessage =
      hideThinking || hideWorkingNote
        ? {
            ...message,
            content: message.content.filter(
              (block) =>
                !(hideThinking && block.type === "thinking") &&
                !(
                  hideWorkingNote &&
                  block.type === "text" &&
                  !calmTextIsSubstantive(block.text)
                ),
            ),
          }
        : message;

    // Older Pi builds take only the message. Passing the streaming flag through keeps
    // the installed signature's default from freezing a stale streaming bit.
    currentUpdateContent.call(this, presentationMessage, isStreaming);
    if (presentationMessage !== message) state.lastMessage = message;
  };

  registry[CALM_ASSISTANT_LAYOUT_PATCH] = patch;
}
