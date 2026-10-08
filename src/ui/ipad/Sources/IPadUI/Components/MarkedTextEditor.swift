import SwiftUI
import UIKit

// TextEditor 不暴露 markedTextRange（输入法尚未上屏的组合区间），正文自动保存必须等待选字完成。
struct MarkedTextEditor: UIViewRepresentable {
    @Binding var text: String
    @Binding var isComposing: Bool
    var onCommittedChange: (String) -> Void = { _ in }

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.font = .preferredFont(forTextStyle: .body)
        view.adjustsFontForContentSizeCategory = true
        view.backgroundColor = .clear
        view.text = text
        view.delegate = context.coordinator
        view.accessibilityLabel = "正文"
        return view
    }
    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.editor = self
        // 外部刷新不能覆盖组合中的拼音；上屏后再接受绑定值，保留光标位置并按 UTF-16 长度夹紧。
        guard view.markedTextRange == nil, view.text != text else { return }
        let selection = view.selectedRange
        view.text = text
        let length = (text as NSString).length
        view.selectedRange = NSRange(location: min(selection.location, length), length: 0)
    }
    func makeCoordinator() -> Coordinator { Coordinator(editor: self) }
    @MainActor final class Coordinator: NSObject, UITextViewDelegate {
        var editor: MarkedTextEditor
        init(editor: MarkedTextEditor) { self.editor = editor }
        func textViewDidChange(_ view: UITextView) {
            let composing = view.markedTextRange != nil
            editor.isComposing = composing
            guard !composing else { return }
            // 绑定中永远只有已上屏文字，后台 flush 不会保存半个拼音。
            editor.text = view.text
            editor.onCommittedChange(view.text)
        }
    }
}
