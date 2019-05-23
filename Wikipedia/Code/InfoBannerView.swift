
import UIKit

class InfoBannerView: UIView {
    
    private let iconImageView = UIImageView()
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupView()
    }
    
    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    func sizeThatFits(_ size: CGSize, apply: Bool) -> CGSize {
        
        let semanticContentAttribute: UISemanticContentAttribute = traitCollection.layoutDirection == .rightToLeft ? .forceRightToLeft : .forceLeftToRight
        let isRTL = semanticContentAttribute == .forceRightToLeft
        
        let adjustedMargins = UIEdgeInsets(top: layoutMargins.top, left: layoutMargins.left, bottom: layoutMargins.bottom, right: layoutMargins.right + 5)
        
        let iconImageSideLength = CGFloat(26)
        let iconTextSpacing = CGFloat(10)
        let titleSubtitleSpacing = UIStackView.spacingUseSystem
        
        let titleLabelOrigin = isRTL ? CGPoint(x: adjustedMargins.left, y: adjustedMargins.top) : CGPoint(x: adjustedMargins.left + iconImageSideLength + iconTextSpacing, y: adjustedMargins.top)
        let titleLabelWidth = size.width - adjustedMargins.left - adjustedMargins.right - iconImageSideLength - iconTextSpacing

        let titleLabelFrame = titleLabel.wmf_preferredFrame(at: titleLabelOrigin, maximumWidth: titleLabelWidth, minimumWidth: titleLabelWidth, alignedBy: semanticContentAttribute, apply: apply)
        
        let subtitleLabelOrigin = CGPoint(x: titleLabelOrigin.x, y: titleLabelFrame.maxY + titleSubtitleSpacing)
        let subtitleLabelWidth = titleLabelWidth
        
        let subtitleLabelFrame = subtitleLabel.wmf_preferredFrame(at: subtitleLabelOrigin, maximumWidth: subtitleLabelWidth, minimumWidth: subtitleLabelWidth, alignedBy: semanticContentAttribute, apply: apply)
        
        let finalHeight = adjustedMargins.top + titleLabelFrame.size.height + subtitleLabelFrame.height + adjustedMargins.bottom
        
        if (apply) {
            iconImageView.frame = isRTL ? CGRect(x: adjustedMargins.left + titleLabelWidth + iconTextSpacing, y: (finalHeight / 2) - (iconImageSideLength / 2), width: iconImageSideLength, height: iconImageSideLength) : CGRect(x: adjustedMargins.left, y: (finalHeight / 2) - (iconImageSideLength / 2), width: iconImageSideLength, height: iconImageSideLength)
        }
        
        return CGSize(width: size.width, height: finalHeight)
    }
    
    override func sizeThatFits(_ size: CGSize) -> CGSize {
        return sizeThatFits(size, apply: false)
    }
    
    func configure(iconName: String, title: String, subtitle: String) {
        iconImageView.image = UIImage.init(named: iconName)
        titleLabel.text = title
        subtitleLabel.text = subtitle
    }
    
    // MARK - Dynamic Type
    // Only applies new fonts if the content size category changes
    
    open override func setNeedsLayout() {
        maybeUpdateFonts(with: traitCollection)
        super.setNeedsLayout()
    }
    
    override open func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        setNeedsLayout()
    }
    
    var contentSizeCategory: UIContentSizeCategory?
    fileprivate func maybeUpdateFonts(with traitCollection: UITraitCollection) {
        guard contentSizeCategory == nil || contentSizeCategory != traitCollection.wmf_preferredContentSizeCategory else {
            return
        }
        contentSizeCategory = traitCollection.wmf_preferredContentSizeCategory
        updateFonts(with: traitCollection)
    }
    
    func updateFonts(with traitCollection: UITraitCollection) {
        titleLabel.font = UIFont.wmf_font(.mediumFootnote, compatibleWithTraitCollection: traitCollection)
        subtitleLabel.font = UIFont.wmf_font(.caption1, compatibleWithTraitCollection: traitCollection)
    }
}

//MARK: Private

private extension InfoBannerView {
    func setupView() {
        preservesSuperviewLayoutMargins = false
        insetsLayoutMarginsFromSafeArea = false
        autoresizesSubviews = false
        addSubview(iconImageView)
        addSubview(titleLabel)
        addSubview(subtitleLabel)
    }
}

//MARK: Themable

extension InfoBannerView: Themeable {
    func apply(theme: Theme) {
        backgroundColor = theme.colors.hintBackground
        titleLabel.textColor = theme.colors.link
        titleLabel.numberOfLines = 0
        subtitleLabel.textColor = theme.colors.link
        subtitleLabel.numberOfLines = 0
    }
}