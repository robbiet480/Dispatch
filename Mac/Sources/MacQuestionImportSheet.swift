import DispatchKit
import SwiftUI

/// Plan 47 (issue #57): the import preview — the `--dry-run`-style sheet that
/// lists what will be added, skipped (duplicates), and rejected (invalid
/// rows) BEFORE anything is written. Confirm commits the adds; cancel writes
/// nothing.
struct MacQuestionImportSheet: View {
    @Environment(\.dismiss) private var dismiss
    let plan: QuestionImportPlan
    let onConfirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Import Questions")
                .font(.title2.weight(.semibold))
                .padding([.top, .horizontal])

            HStack(spacing: 20) {
                countTile("Add", plan.addCount, .green)
                countTile("Skip", plan.skipCount, .secondary)
                countTile("Error", plan.errorCount, plan.errorCount > 0 ? .red : .secondary)
            }
            .padding()

            List {
                if !plan.adds.isEmpty {
                    Section("Will be added") {
                        ForEach(Array(plan.adds.enumerated()), id: \.offset) { _, def in
                            Label(def.prompt, systemImage: "plus.circle")
                                .lineLimit(1)
                        }
                    }
                }
                if !plan.skips.isEmpty {
                    Section("Skipped (already exist)") {
                        ForEach(Array(plan.skips.enumerated()), id: \.offset) { _, skip in
                            Label(skip.prompt.isEmpty ? "(empty prompt)" : skip.prompt,
                                  systemImage: "equal.circle")
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
                if !plan.errors.isEmpty {
                    Section("Errors (won't import)") {
                        ForEach(Array(plan.errors.enumerated()), id: \.offset) { _, rowError in
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Row \(rowError.index + 1): \(rowError.prompt.isEmpty ? "(empty prompt)" : rowError.prompt)")
                                    .lineLimit(1)
                                Text(rowError.errors.map(\.message).joined(separator: " "))
                                    .font(.caption).foregroundStyle(.red)
                            }
                        }
                    }
                }
            }
            .accessibilityIdentifier("mac-question-import-sheet")

            Divider()
            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Import \(plan.addCount)") {
                    onConfirm()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(plan.addCount == 0)
                .accessibilityIdentifier("mac-question-import-confirm")
            }
            .padding()
        }
        .frame(minWidth: 480, minHeight: 460)
    }

    private func countTile(_ label: String, _ count: Int, _ color: Color) -> some View {
        VStack {
            Text("\(count)").font(.largeTitle.weight(.bold)).foregroundStyle(color)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}
