import SwiftUI
import UIKit

// 原生看大图（老板 2026-11-22：私信点图片应该用苹果自带相册那套交互）：
// 双指缩放、双击放大/还原、放大后拖动、未放大时下滑关闭（跟手缩小 + 背景渐隐）、单击切换工具栏、左右滑切换多张。
// 用 UIScrollView 做缩放——跟「照片」App 同一套物理手感；不用网页自带的看图层（它在触屏上没有关闭方式）。

struct DYPhotoViewerTarget: Identifiable {
    let id = UUID()
    let urls: [URL]
    let start: Int
    /// 网页里已显示的图片像素（base64 解出来的），原图取不到时兜底
    var fallbacks: [Data?] = []
}

struct DYPhotoViewer: UIViewControllerRepresentable {
    let target: DYPhotoViewerTarget
    let onClose: () -> Void

    func makeUIViewController(context: Context) -> DYPhotoPagerController {
        DYPhotoPagerController(urls: target.urls, fallbacks: target.fallbacks, start: target.start, onClose: onClose)
    }
    func updateUIViewController(_ vc: DYPhotoPagerController, context: Context) {}
}

extension View {
    /// 挂原生看大图：item 非 nil 时全屏淡入
    func dyPhotoViewer(_ item: Binding<DYPhotoViewerTarget?>) -> some View {
        fullScreenCover(item: item) { t in
            DYPhotoViewer(target: t) { item.wrappedValue = nil }
                .ignoresSafeArea()
                .presentationBackground(.clear)
        }
        .transaction { if item.wrappedValue != nil { $0.disablesAnimations = true } }
    }
}

final class DYPhotoPagerController: UIViewController, UIPageViewControllerDataSource, UIPageViewControllerDelegate {
    private let urls: [URL]
    private let fallbacks: [Data?]
    private var index: Int
    private let onClose: () -> Void
    private let pager = UIPageViewController(transitionStyle: .scroll, navigationOrientation: .horizontal,
                                            options: [.interPageSpacing: 20])
    private let backdrop = UIView()
    private let closeButton = UIButton(type: .system)
    private let counter = UILabel()
    private var chromeHidden = false

    init(urls: [URL], fallbacks: [Data?] = [], start: Int, onClose: @escaping () -> Void) {
        self.urls = urls
        self.fallbacks = fallbacks
        self.index = min(max(start, 0), max(urls.count - 1, 0))
        self.onClose = onClose
        super.init(nibName: nil, bundle: nil)
        modalPresentationCapturesStatusBarAppearance = true
    }
    required init?(coder: NSCoder) { fatalError() }

    override var prefersStatusBarHidden: Bool { true }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        backdrop.backgroundColor = .black
        backdrop.frame = view.bounds
        backdrop.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(backdrop)

        addChild(pager)
        pager.view.frame = view.bounds
        pager.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        pager.view.backgroundColor = .clear
        view.addSubview(pager.view)
        pager.didMove(toParent: self)
        pager.dataSource = urls.count > 1 ? self : nil
        pager.delegate = self
        if let first = page(at: index) { pager.setViewControllers([first], direction: .forward, animated: false) }

        var cfg = UIButton.Configuration.filled()
        cfg.image = UIImage(systemName: "xmark", withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold))
        cfg.baseForegroundColor = .white
        cfg.baseBackgroundColor = UIColor.black.withAlphaComponent(0.45)
        cfg.cornerStyle = .capsule
        closeButton.configuration = cfg
        closeButton.accessibilityLabel = "关闭"
        closeButton.accessibilityIdentifier = "douyin.photo.close"
        closeButton.addAction(UIAction { [weak self] _ in self?.close() }, for: .touchUpInside)
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(closeButton)

        counter.textColor = .white
        counter.font = .preferredFont(forTextStyle: .subheadline)
        counter.translatesAutoresizingMaskIntoConstraints = false
        counter.isHidden = urls.count < 2
        view.addSubview(counter)
        updateCounter()

        let g = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            closeButton.topAnchor.constraint(equalTo: g.topAnchor, constant: 12),
            closeButton.leadingAnchor.constraint(equalTo: g.leadingAnchor, constant: 16),
            closeButton.widthAnchor.constraint(equalToConstant: 40),
            closeButton.heightAnchor.constraint(equalToConstant: 40),
            counter.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            counter.centerYAnchor.constraint(equalTo: closeButton.centerYAnchor),
        ])
    }

    private func page(at i: Int) -> DYPhotoPage? {
        guard urls.indices.contains(i) else { return nil }
        let p = DYPhotoPage(url: urls[i], index: i)
        p.fallback = fallbacks.indices.contains(i) ? fallbacks[i] : nil
        p.onSingleTap = { [weak self] in self?.toggleChrome() }
        p.onDismissProgress = { [weak self] f in self?.setDismissProgress(f) }
        p.onDismiss = { [weak self] in self?.close(animatedFromPage: true) }
        return p
    }

    private func updateCounter() { counter.text = "\(index + 1) / \(urls.count)" }

    private func toggleChrome() {
        chromeHidden.toggle()
        UIView.animate(withDuration: 0.2) {
            self.closeButton.alpha = self.chromeHidden ? 0 : 1
            self.counter.alpha = self.chromeHidden ? 0 : 1
        }
    }

    /// 下滑过程中：背景随距离变透明，工具栏淡出
    private func setDismissProgress(_ f: CGFloat) {
        backdrop.alpha = 1 - min(max(f, 0), 1) * 0.9
        let chrome: CGFloat = chromeHidden ? 0 : (f > 0.02 ? 0 : 1)
        closeButton.alpha = chrome
        counter.alpha = chrome
    }

    private func close(animatedFromPage: Bool = false) {
        DYLiveModel.log("DDPHOTO close via=\(animatedFromPage ? "swipe" : "button")")
        if animatedFromPage {
            onClose()
        } else {
            UIView.animate(withDuration: 0.18, animations: { self.view.alpha = 0 }) { _ in self.onClose() }
        }
    }

    func pageViewController(_ pvc: UIPageViewController, viewControllerBefore vc: UIViewController) -> UIViewController? {
        page(at: ((vc as? DYPhotoPage)?.index ?? index) - 1)
    }
    func pageViewController(_ pvc: UIPageViewController, viewControllerAfter vc: UIViewController) -> UIViewController? {
        page(at: ((vc as? DYPhotoPage)?.index ?? index) + 1)
    }
    func pageViewController(_ pvc: UIPageViewController, didFinishAnimating finished: Bool,
                            previousViewControllers: [UIViewController], transitionCompleted completed: Bool) {
        if completed, let p = pvc.viewControllers?.first as? DYPhotoPage { index = p.index; updateCounter() }
    }
}

/// 单张：UIScrollView 缩放 + 下滑关闭
final class DYPhotoPage: UIViewController, UIScrollViewDelegate, UIGestureRecognizerDelegate {
    let url: URL
    let index: Int
    /// 网页上已经显示出来的那张（截下来的像素），原图取不到时用它
    var fallback: Data?
    var onSingleTap: (() -> Void)?
    var onDismissProgress: ((CGFloat) -> Void)?
    var onDismiss: (() -> Void)?

    private let scroll = UIScrollView()
    private let imageView = UIImageView()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private var pan: UIPanGestureRecognizer!
    private var lastSize: CGSize = .zero

    init(url: URL, index: Int) {
        self.url = url
        self.index = index
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        scroll.frame = view.bounds
        scroll.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        scroll.delegate = self
        scroll.minimumZoomScale = 1
        scroll.maximumZoomScale = 4
        scroll.showsHorizontalScrollIndicator = false
        scroll.showsVerticalScrollIndicator = false
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.decelerationRate = .fast
        view.addSubview(scroll)
        imageView.contentMode = .scaleAspectFit
        imageView.isUserInteractionEnabled = true
        imageView.accessibilityIdentifier = "douyin.photo.image"
        scroll.addSubview(imageView)

        spinner.color = .white
        spinner.center = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
        spinner.autoresizingMask = [.flexibleLeftMargin, .flexibleRightMargin, .flexibleTopMargin, .flexibleBottomMargin]
        spinner.startAnimating()
        view.addSubview(spinner)

        let double = UITapGestureRecognizer(target: self, action: #selector(doubleTap(_:)))
        double.numberOfTapsRequired = 2
        scroll.addGestureRecognizer(double)
        let single = UITapGestureRecognizer(target: self, action: #selector(singleTap))
        single.require(toFail: double)
        scroll.addGestureRecognizer(single)
        pan = UIPanGestureRecognizer(target: self, action: #selector(dismissPan(_:)))
        pan.delegate = self
        view.addGestureRecognizer(pan)

        load()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if scroll.bounds.size != lastSize {
            lastSize = scroll.bounds.size
            scroll.setZoomScale(1, animated: false)
            layoutImage()
        }
    }

    private func load() {
        // 先把网页上已显示的那张铺上（秒开），原图拿到了再替换
        if let fallback, let img = UIImage(data: fallback) {
            spinner.stopAnimating()
            imageView.image = img
            layoutImage()
        }
        Task { @MainActor in
            let raw = DYChatImageCache.originalURL(url.absoluteString) ?? url.absoluteString
            var data: Data?
            if url.scheme == "data", let comma = raw.firstIndex(of: ",") {
                // 内嵌 base64（私信图片缩略图）：直接解码
                data = Data(base64Encoded: String(raw[raw.index(after: comma)...]), options: .ignoreUnknownCharacters)
            } else {
                data = DYChatImageCache.shared.cachedData(for: raw)
            }
            if data == nil, url.scheme != "data", let u = URL(string: raw) {
                var req = URLRequest(url: u, timeoutInterval: 20)
                req.setValue("https://www.douyin.com/", forHTTPHeaderField: "Referer")
                req.setValue(DouyinWeb.userAgent, forHTTPHeaderField: "User-Agent")
                do {
                    let (d, resp) = try await URLSession.shared.data(for: req)
                    let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
                    let type = (resp as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type") ?? "-"
                    DYLiveModel.log("DDPHOTO fetch http=\(code) bytes=\(d.count) type=\(type) host=\(u.host ?? "-") path=\(u.path.prefix(60)) ext=\(u.pathExtension)")
                    if code == 200, UIImage(data: d) != nil { data = d; DYChatImageCache.shared.store(d, for: raw) }
                } catch { DYLiveModel.log("DDPHOTO fetch err \(error.localizedDescription)") }
            }
            // 网络原图取不到（加密 / 鉴权）时退回网页上已显示的那张（App 在点击时一并带过来）
            if data == nil, let fallback { data = fallback }
            spinner.stopAnimating()
            if data == nil, imageView.image != nil { return }   // 原图取不到，留着已显示的那张
            guard let data, let img = UIImage(data: data) else {
                DYLiveModel.log("DDPHOTO load fail")
                let l = UILabel(); l.text = "图片加载失败"; l.textColor = .white; l.sizeToFit()
                l.center = CGPoint(x: view.bounds.midX, y: view.bounds.midY); view.addSubview(l)
                return
            }
            imageView.image = img
            layoutImage()
        }
    }

    /// 图片按比例铺进可视区，放大后居中
    private func layoutImage() {
        guard let img = imageView.image, scroll.bounds.width > 0 else { return }
        let b = scroll.bounds.size
        let s = min(b.width / img.size.width, b.height / img.size.height)
        let size = CGSize(width: img.size.width * s, height: img.size.height * s)
        imageView.frame = CGRect(origin: .zero, size: size)
        scroll.contentSize = size
        // 长图放大到铺满宽度要能看清：最大放大 = max(4, 铺满宽度所需倍数×2)
        scroll.maximumZoomScale = max(4, (b.width / size.width) * 2)
        center()
    }

    private func center() {
        let b = scroll.bounds.size, c = scroll.contentSize
        scroll.contentInset = UIEdgeInsets(top: max(0, (b.height - c.height) / 2), left: max(0, (b.width - c.width) / 2),
                                           bottom: 0, right: 0)
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }
    func scrollViewDidZoom(_ scrollView: UIScrollView) { center() }

    @objc private func singleTap() { onSingleTap?() }

    /// 双击：没放大就放大到点的位置（2.5 倍或铺满），放大了就还原
    @objc private func doubleTap(_ g: UITapGestureRecognizer) {
        if scroll.zoomScale > scroll.minimumZoomScale + 0.01 {
            scroll.setZoomScale(scroll.minimumZoomScale, animated: true)
            return
        }
        let p = g.location(in: imageView)
        let fill = max(scroll.bounds.width / max(imageView.bounds.width, 1), scroll.bounds.height / max(imageView.bounds.height, 1))
        let target = min(scroll.maximumZoomScale, max(2.5, fill))
        let w = scroll.bounds.width / target, h = scroll.bounds.height / target
        scroll.zoom(to: CGRect(x: p.x - w / 2, y: p.y - h / 2, width: w, height: h), animated: true)
    }

    // MARK: 下滑关闭（只在未放大时生效；放大时交给 scroll 拖动）

    func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
        guard g === pan else { return true }
        guard scroll.zoomScale <= scroll.minimumZoomScale + 0.01 else { return false }
        let v = pan.velocity(in: view)
        return v.y > 0 && abs(v.y) > abs(v.x)
    }

    @objc private func dismissPan(_ g: UIPanGestureRecognizer) {
        let t = g.translation(in: view)
        let progress = max(0, t.y) / max(view.bounds.height * 0.5, 1)
        switch g.state {
        case .changed:
            let scale = 1 - min(progress, 1) * 0.35
            scroll.transform = CGAffineTransform(translationX: t.x, y: max(0, t.y)).scaledBy(x: scale, y: scale)
            onDismissProgress?(progress)
        case .ended, .cancelled:
            let v = g.velocity(in: view).y
            if g.state == .ended && (progress > 0.25 || v > 900) {
                UIView.animate(withDuration: 0.22, delay: 0, options: .curveEaseOut, animations: {
                    self.scroll.transform = CGAffineTransform(translationX: t.x, y: self.view.bounds.height).scaledBy(x: 0.6, y: 0.6)
                    self.scroll.alpha = 0
                    self.onDismissProgress?(1)
                }) { _ in self.onDismiss?() }
            } else {
                UIView.animate(withDuration: 0.3, delay: 0, usingSpringWithDamping: 0.85, initialSpringVelocity: 0, animations: {
                    self.scroll.transform = .identity
                    self.onDismissProgress?(0)
                })
            }
        default: break
        }
    }
}

