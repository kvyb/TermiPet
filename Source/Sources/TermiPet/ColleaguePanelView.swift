import SwiftUI
import TermiPetCore

/// Explicit reply target for the colleague panel.
///
/// A new comment from another session never moves an explicit selection, so an
/// in-progress draft cannot silently land in the wrong thread.
struct ColleagueThreadSelection: Equatable {
    private(set) var selectedThreadID: UUID?

    /// Returns true when a previously selected thread disappeared, which the view
    /// treats as "drop the draft" instead of retargeting it.
    mutating func sync(with threads: [PiColleagueThread]) -> Bool {
        if let selectedThreadID, threads.contains(where: { $0.id == selectedThreadID }) {
            return false
        }
        let hadSelection = selectedThreadID != nil
        selectedThreadID = threads.last?.id
        return hadSelection
    }

    mutating func select(_ id: UUID) {
        selectedThreadID = id
    }

    func target(in threads: [PiColleagueThread]) -> PiColleagueThread? {
        if let selectedThreadID, let thread = threads.first(where: { $0.id == selectedThreadID }) {
            return thread
        }
        return threads.last
    }
}

/// Colleague tab inside the pet chat panel.
///
/// Kept separate from the pet conversation on purpose: comments come from the
/// tagged humanlike endpoint with a colleague-only system prompt, and each
/// source session gets its own thread so excerpts never blend into one
/// fabricated conversation.
struct ColleaguePanelView: View {
    @ObservedObject var controller: PiColleagueController
    var localizer: AppLocalizer = AppLocalizer()

    @State private var replyText = ""
    @State private var selection = ColleagueThreadSelection()
    @FocusState private var replyFocused: Bool

    private var selectedThread: PiColleagueThread? {
        selection.target(in: controller.threads)
    }

    private var canInteract: Bool {
        controller.isOwned && !controller.stateIsCorrupt
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            Text(localizer[.colleagueDisclosure])
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if controller.stateIsCorrupt {
                Text(localizer[.colleagueStateCorrupt])
                    .font(.system(size: 10.5))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else if !controller.isOwned {
                Text(localizer[.colleagueNotOwner])
                    .font(.system(size: 10.5))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else if controller.storageFailed {
                Text(localizer[.colleagueSaveFailed])
                    .font(.system(size: 10.5))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if controller.threads.isEmpty {
                Text(localizer[.colleagueEmpty])
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                threadsArea
            }

            replyRow
        }
        .frame(width: 264)
        .onAppear {
            _ = selection.sync(with: controller.threads)
            markSelectedRead()
        }
        .onChangeCompat(of: controller.threads) { threads in
            if selection.sync(with: threads), !replyText.isEmpty {
                replyText = ""
            }
            markSelectedRead()
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text(localizer[.colleagueEnable])
                .font(.system(size: 12, weight: .semibold))
            Spacer(minLength: 4)
            Toggle("", isOn: Binding(
                get: { controller.settings.isEnabled },
                set: { controller.setEnabled($0) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.mini)
            .disabled(!canInteract)
        }
    }

    private var threadsArea: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(controller.threads) { thread in
                        threadBlock(thread)
                    }
                    Color.clear.frame(height: 1).id("colleague-bottom")
                }
                .padding(.horizontal, 2)
                .padding(.vertical, 2)
            }
            .frame(maxHeight: 190)
            .onChangeCompat(of: controller.threads) { _ in scrollDown(proxy) }
            .onAppear { scrollDown(proxy) }
        }
    }

    private func threadBlock(_ thread: PiColleagueThread) -> some View {
        let isSelected = selectedThread?.id == thread.id
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text(thread.label)
                    .font(.system(size: 10, weight: isSelected ? .bold : .semibold))
                    .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                    .lineLimit(1)
                if thread.hasUnread {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 5, height: 5)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture { select(thread) }

            ForEach(thread.messages) { message in
                BubbleRow(message: message)
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isSelected ? Color.primary.opacity(0.09) : Color.clear)
        )
    }

    private var replyRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let target = selectedThread {
                HStack(spacing: 4) {
                    Image(systemName: "arrowshape.turn.up.left.fill")
                        .font(.system(size: 9, weight: .bold))
                    Text(String(format: localizer[.colleagueReplyTo], target.label))
                        .font(.system(size: 10, weight: .semibold))
                        .lineLimit(1)
                }
                .foregroundStyle(.secondary)
            }

            HStack(spacing: 6) {
                TextField(localizer[.colleagueReplyPlaceholder], text: $replyText)
                    .font(.system(size: 13, weight: .medium))
                    .textFieldStyle(.plain)
                    .focused($replyFocused)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .frame(maxWidth: .infinity)
                    .background(.regularMaterial, in: Capsule())
                    .overlay(
                        Capsule().strokeBorder(Color.white.opacity(0.22), lineWidth: 0.8)
                    )
                    .disabled(selectedThread == nil || controller.isReplying || !canInteract)
                    .onSubmit { commit() }

                Button {
                    commit()
                } label: {
                    Image(systemName: controller.isReplying ? "hourglass" : "arrow.up.circle.fill")
                        .font(.system(size: 26))
                        .foregroundStyle(canReply ? Color.blue : Color.secondary)
                        .symbolRenderingMode(.hierarchical)
                }
                .buttonStyle(.plain)
                .disabled(!canReply)
            }
            .overlay(alignment: .bottomLeading) {
                if controller.lastReplyFailed {
                    Text(localizer[.colleagueReplyFailed])
                        .font(.system(size: 10.5))
                        .foregroundStyle(.orange)
                        .offset(y: 12)
                }
            }
        }
    }

    private var canReply: Bool {
        canInteract
            && !replyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !controller.isReplying
            && selectedThread != nil
    }

    private func select(_ thread: PiColleagueThread) {
        selection.select(thread.id)
        markSelectedRead()
    }

    private func markSelectedRead() {
        guard let thread = selectedThread else { return }
        controller.markRead(threadID: thread.id)
    }

    private func commit() {
        let trimmed = replyText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canReply, let thread = selectedThread else { return }
        replyText = ""
        controller.reply(threadID: thread.id, text: trimmed)
    }

    private func scrollDown(_ proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.12)) {
            proxy.scrollTo("colleague-bottom", anchor: .bottom)
        }
    }
}
