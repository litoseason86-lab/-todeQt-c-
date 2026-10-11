import IPadCore
import SwiftUI
import UIKit

// 标题和正文都受组合保护；单行回车去正文，尚在选字时回车交给输入法。
@MainActor struct MemoTitleEditor: UIViewRepresentable {
    var text: String
    var isComposing: Bool
    var focusGeneration: Int
    var onComposition: (Bool) -> Void
    var onText: (String) -> Void
    func makeUIView(context: Context) -> UITextField {
        let field = UITextField(); field.accessibilityLabel = "标题"
        field.textColor = UIColor(ThemeColors.inputInk)
        // 定稿纸面标题 24 粗，随系统字号缩放。
        field.font = UIFontMetrics(forTextStyle: .title2).scaledFont(for: .systemFont(ofSize: 24, weight: .bold)); field.adjustsFontForContentSizeCategory = true
        field.delegate = context.coordinator; field.text = text; field.returnKeyType = .next
        field.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .editingChanged)
        return field
    }
    func updateUIView(_ field: UITextField, context: Context) {
        context.coordinator.editor = self
        if field.markedTextRange == nil && field.text != text { field.text = text }
        if context.coordinator.focusGeneration != focusGeneration {
            context.coordinator.focusGeneration = focusGeneration
            if focusGeneration > 0 {
                let generation = focusGeneration
                // 新建后详情可能尚未入窗口；下一主队列周期再聚焦，过期的焦点请求不得抢新会话。
                Task { @MainActor [weak field, weak coordinator = context.coordinator] in
                    guard coordinator?.focusGeneration == generation, field?.window != nil else { return }
                    field?.becomeFirstResponder()
                }
            }
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator(editor: self) }
    @MainActor final class Coordinator: NSObject, UITextFieldDelegate {
        var editor: MemoTitleEditor
        var focusGeneration = 0
        init(editor: MemoTitleEditor) { self.editor = editor }
        @objc func changed(_ field: UITextField) {
            let composing = field.markedTextRange != nil
            editor.onComposition(composing)
            if !composing {
                let value = field.text ?? ""
                // 单行标题沿用 Mac 的 60 个 UTF-16 单元输入上限；组合期间不截断候选。
                if MemoFormat.characterCount(value) > 60 {
                    let limited = String(decoding: MemoFormat.firstCharacters(value, count: 60), as: UTF16.self)
                    field.text = limited; editor.onText(limited)
                } else { editor.onText(value) }
            }
        }
        func textFieldDidEndEditing(_ field: UITextField) { changed(field) }
        func textFieldShouldReturn(_ field: UITextField) -> Bool {
            guard field.markedTextRange == nil else { return false }
            // 复用 P3A 正文编辑器的无障碍名称寻找本页正文，不修改其组合保护实现。
            func body(in view: UIView) -> UITextView? {
                if let text = view as? UITextView, text.accessibilityLabel == "正文" { return text }
                for child in view.subviews { if let text = body(in: child) { return text } }
                return nil
            }
            var ancestor = field.superview
            while let view = ancestor {
                if let text = body(in: view) { text.selectedRange = NSRange(location: 0, length: 0); text.becomeFirstResponder(); break }
                ancestor = view.superview
            }
            return false
        }
    }
}

// P3A 编辑器只转发上屏文字；补结束编辑回调，保证切页与后台在 flush 前拿到已提交组合。
extension MarkedTextEditor.Coordinator {
    @objc func textViewDidEndEditing(_ view: UITextView) { textViewDidChange(view) }
    @objc func textViewDidBeginEditing(_ view: UITextView) { view.textColor = UIColor(ThemeColors.inputInk) }
}
