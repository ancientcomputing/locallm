import OpenJevKit
import SwiftUI

/// Left pane: the system instructions and the questions.
struct EditorView: View {
    @Bindable var model: AppModel
    @State private var showSystem = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                TextField("Question set name", text: $model.set.name)
                    .textFieldStyle(.plain)
                    .font(.jTitle3.weight(.semibold))

                DisclosureGroup(isExpanded: $showSystem) {
                    TextEditor(text: $model.set.system)
                        .font(.system(size: 14, design: .monospaced))
                        .frame(minHeight: 90)
                        .scrollContentBackground(.hidden)
                        .padding(6)
                        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                    Text("Local only: hosted Jev (Featherless, TypeSafe) never sees these instructions or the input's name, just the input and each question's text. Put anything a question needs into the question itself.")
                        .font(.jCaption)
                        .foregroundStyle(.secondary)
                    HStack {
                        Text("Input is called").font(.jCallout)
                        TextField("Input", text: $model.set.inputLabel)
                            .frame(width: 120)
                        Text("in the prompt").font(.jCallout).foregroundStyle(.secondary)
                    }
                } label: {
                    Label("System instructions", systemImage: "text.alignleft")
                        .font(.jCallout.weight(.medium))
                }

                ForEach($model.set.questions) { $q in
                    QuestionCard(question: $q, model: model)
                }

                Menu {
                    ForEach(QuestionKind.allCases, id: \.self) { kind in
                        Button(kind.displayName) { model.addQuestion(kind) }
                    }
                } label: {
                    Label("Add question", systemImage: "plus")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()

                Text("""
                    Tips from the eval: yes/no and multiple choice beat scales on small models; give \
                    options short descriptions; only ask what a model can judge from the input and \
                    stable general knowledge, never current facts.
                    """)
                    .font(.jCaption)
                    .foregroundStyle(.secondary)
            }
            .padding()
        }
    }
}

struct QuestionCard: View {
    @Binding var question: EditableQuestion
    let model: AppModel

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    TextField("name", text: $question.name)
                        .font(.system(size: 14, design: .monospaced).weight(.semibold))
                        .textFieldStyle(.plain)
                    Spacer()
                    Picker("", selection: $question.kind) {
                        ForEach(QuestionKind.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .onChange(of: question.kind) { _, kind in fillOptionsIfNeeded(kind) }
                    Menu {
                        Button("Duplicate (to compare wordings)") { model.duplicate(question) }
                        Button("Move up") { model.move(question, by: -1) }
                        Button("Move down") { model.move(question, by: 1) }
                        Divider()
                        Button("Delete", role: .destructive) { model.remove(question) }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }

                TextField("Question the model reads", text: $question.text, axis: .vertical)
                    .lineLimit(1 ... 4)

                if question.kind != .noul {
                    optionsEditor
                }
                if question.kind == .score {
                    Label("Small models score worst on scales. Try yes/no or multiple choice.", systemImage: "info.circle")
                        .font(.jCaption)
                        .foregroundStyle(.secondary)
                }
                ForEach(question.problems, id: \.self) { p in
                    Label(p, systemImage: "exclamationmark.triangle")
                        .font(.jCaption)
                        .foregroundStyle(.orange)
                }
            }
            .padding(4)
        }
    }

    private var optionsEditor: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array($question.options.enumerated()), id: \.element.id) { i, $opt in
                HStack(spacing: 6) {
                    Text(question.kind == .choice ? String(UnicodeScalar(UInt8(65 + min(i, 25)))) : String(i))
                        .font(.system(size: 12, design: .monospaced).weight(.bold))
                        .frame(width: 18, height: 18)
                        .background(.tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 4))
                    if question.kind == .choice {
                        TextField("key", text: $opt.key)
                            .font(.system(size: 14, design: .monospaced))
                            .frame(width: 110)
                    }
                    TextField("description the model reads", text: $opt.description)
                    Button {
                        question.options.removeAll { $0.id == opt.id }
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .disabled(question.options.count <= 2)
                }
            }
            Button {
                let n = question.options.count
                question.options.append(AnswerOption(key: question.kind == .score ? String(n) : "option\(n + 1)", description: ""))
            } label: {
                Label("Add option", systemImage: "plus.circle")
            }
            .buttonStyle(.borderless)
            .font(.jCallout)
        }
    }

    private func fillOptionsIfNeeded(_ kind: QuestionKind) {
        guard kind != .noul, question.options.count < 2 else { return }
        question.options = kind == .score
            ? [AnswerOption(key: "0", description: "low"), AnswerOption(key: "1", description: "medium"), AnswerOption(key: "2", description: "high")]
            : [AnswerOption(key: "first", description: ""), AnswerOption(key: "second", description: "")]
    }
}
