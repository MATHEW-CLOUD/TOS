import UIKit
import NGExtensions

open class TitleTextField: TextField {
    open var borderInactiveColor: UIColor? {
        didSet {
            updateBorder()
        }
    }

    /**
     The color of the border when it has content.

     This property applies a color to the lower edge of the control. The default value for this property is a clear color.
     */
    @IBInspectable dynamic open var borderActiveColor: UIColor? = .white.withAlphaComponent(0.25) {
        didSet {
            updateBorder()
        }
    }

    /**
     The color of the placeholder text.
     This property applies a color to the complete placeholder string. The default value for this property is a black color.
     */
    @IBInspectable dynamic open var placeholderColor: UIColor = .white.withAlphaComponent(0.4) {
        didSet {
            updatePlaceholder()
        }
    }

    /**
     The scale of the placeholder font.

     This property determines the size of the placeholder label relative to the font size of the text field.
    */
    @IBInspectable dynamic open var placeholderFontScale: CGFloat = 1.0 {
        didSet {
            updatePlaceholder()
        }
    }

    override open var placeholder: String? {
        didSet {
            updatePlaceholder()
        }
    }

    open var errorText: String?
    open var showError: Bool = false {
        didSet {
            updateError()
        }
    }


    override open var bounds: CGRect {
        didSet {
            updateBorder()
            updatePlaceholder()
        }
    }

    private let borderThickness: (active: CGFloat, inactive: CGFloat) = (active: 0.25, inactive: 0.25)
    private let placeholderInsets = CGPoint(x: 0, y: 6)
    private let errorInsets = CGPoint(x: 0, y: 18)
    private let textFieldInsets = CGPoint(x: 0, y: 12)
    private let inactiveBorderLayer = CALayer()
    private let activeBorderLayer = CALayer()
    private var activePlaceholderPoint: CGPoint = CGPoint.zero

    // MARK: - TextFieldEffects

    override open func drawViewsForRect(_ rect: CGRect) {
        if Locale.current.languageCode == "ar" {
            if textAlignment == .natural {
                textAlignment = .right
            }
        }
        let frame = CGRect(origin: CGPoint.zero, size: CGSize(width: rect.size.width, height: rect.size.height))

        placeholderLabel.frame = frame.insetBy(dx: placeholderInsets.x, dy: placeholderInsets.y)
        placeholderLabel.font = placeholderFontFromFont(font!)

        errorLabel.frame = frame.insetBy(dx: placeholderInsets.x, dy: errorInsets.y)
        errorLabel.font = .systemFont(ofSize: 14.0)
        errorLabel.textColor = .ngRedAlert
        errorLabel.isHidden = !showError

        updateError()
        updateBorder()
        updatePlaceholder()

        layer.addSublayer(inactiveBorderLayer)
        layer.addSublayer(activeBorderLayer)
        addSubview(placeholderLabel)
        addSubview(errorLabel)
    }

    override open func animateViewsForTextEntry() {
        if text!.isEmpty {
            UIView.animate(withDuration: 0.3, delay: 0.0, usingSpringWithDamping: 0.8, initialSpringVelocity: 1.0, options: .beginFromCurrentState, animations: ({
                self.placeholderLabel.frame.origin = CGPoint(x: 10, y: self.placeholderLabel.frame.origin.y)
                self.placeholderLabel.alpha = 0
            }), completion: { _ in
                self.animationCompletionHandler?(.textEntry)
            })
        }

        layoutPlaceholderInTextRect()
        placeholderLabel.frame.origin = activePlaceholderPoint

        UIView.animate(withDuration: 0.4, animations: {
            self.placeholderLabel.alpha = 1.0
        })

        activeBorderLayer.frame = rectForBorder(borderThickness.active)
    }

    override open func animateViewsForTextDisplay() {
        if let text = text, text.isEmpty {
            UIView.animate(withDuration: 0.35, delay: 0.0, usingSpringWithDamping: 0.8, initialSpringVelocity: 2.0, options: .beginFromCurrentState, animations: ({
                self.layoutPlaceholderInTextRect()
                self.placeholderLabel.alpha = 1
            }), completion: { _ in
                self.animationCompletionHandler?(.textDisplay)
            })

            activeBorderLayer.frame = self.rectForBorder(self.borderThickness.active)
            inactiveBorderLayer.frame = self.rectForBorder(self.borderThickness.inactive)

        }
    }
    
    // MARK: - Public
    
    public func togglePasswordVisibility() {
        isSecureTextEntry.toggle()
        
        if let existingText = text, isSecureTextEntry {
            deleteBackward()
            
            if let textRange = textRange(from: beginningOfDocument, to: endOfDocument) {
                replace(textRange, withText: existingText)
            }
        }

        if let existingSelectedTextRange = selectedTextRange {
            selectedTextRange = nil
            selectedTextRange = existingSelectedTextRange
        }
    }

    // MARK: - Private

    private func updateBorder() {
        inactiveBorderLayer.frame = rectForBorder(borderThickness.inactive)
        inactiveBorderLayer.backgroundColor = borderInactiveColor?.cgColor

        activeBorderLayer.frame = rectForBorder(borderThickness.active)
        activeBorderLayer.backgroundColor = borderActiveColor?.cgColor
    }

    private func updatePlaceholder() {
        placeholderLabel.text = placeholder
        placeholderLabel.textColor = placeholderColor
        placeholderLabel.sizeToFit()
        layoutPlaceholderInTextRect()

        if isFirstResponder || text!.isNotEmpty {
            animateViewsForTextEntry()
        }
    }

    private func updateError() {
        errorLabel.text = errorText
        errorLabel.isHidden = !showError
        errorLabel.sizeToFit()
        
        inactiveBorderLayer.frame = rectForBorder(borderThickness.inactive)
        inactiveBorderLayer.backgroundColor = UIColor.ngRedAlert.cgColor
        
        activeBorderLayer.frame = rectForBorder(borderThickness.active)
        activeBorderLayer.backgroundColor = UIColor.ngRedAlert.cgColor
        
        layoutErrorInTextRect()
    }

    private func placeholderFontFromFont(_ font: UIFont) -> UIFont! {
        let smallerFont = UIFont(descriptor: font.fontDescriptor, size: font.pointSize * placeholderFontScale)
        return smallerFont
    }

    private func rectForBorder(_ thickness: CGFloat) -> CGRect {
        return CGRect(origin: CGPoint(x: 0, y: frame.height-thickness), size: CGSize(width: frame.width, height: thickness))
    }

    private func layoutPlaceholderInTextRect() {
        let textRect = self.textRect(forBounds: bounds)
        var originX = textRect.origin.x
        switch self.textAlignment {
        case .center:
            originX += textRect.size.width/2 - placeholderLabel.bounds.width/2
        case .right:
            originX += textRect.size.width - placeholderLabel.bounds.width
        default:
            break
        }
        placeholderLabel.frame = CGRect(
            x: originX,
            y: textRect.height / 2,
            width: placeholderLabel.bounds.width,
            height: placeholderLabel.bounds.height
        )
        activePlaceholderPoint = CGPoint(x: placeholderLabel.frame.origin.x, y: placeholderLabel.frame.origin.y - placeholderLabel.frame.size.height - placeholderInsets.y)
    }

    private func layoutErrorInTextRect() {
        let textRect = self.textRect(forBounds: bounds)
        let originX = textRect.origin.x
        errorLabel.frame = CGRect(
            x: originX,
            y: textRect.height / 2 + 34.0,
            width: errorLabel.bounds.width,
            height: errorLabel.bounds.height
        )
    }

    // MARK: - Overrides

    override open func editingRect(forBounds bounds: CGRect) -> CGRect {
        return bounds.offsetBy(dx: textFieldInsets.x, dy: textFieldInsets.y)
    }

    override open func textRect(forBounds bounds: CGRect) -> CGRect {
        return bounds.offsetBy(dx: textFieldInsets.x, dy: textFieldInsets.y)
    }
    
    open override func textFieldDidBeginEditing() {
        super.textFieldDidBeginEditing()
        
        updateBorder()
    }
}