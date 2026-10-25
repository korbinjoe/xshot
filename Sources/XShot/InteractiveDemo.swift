import AppKit
import WebKit

enum InteractiveDemoExporter {
    enum ExportError: LocalizedError {
        case noSteps, invalidImage(String)
        var errorDescription: String? {
            switch self {
            case .noSteps: return "演示还没有步骤。请先录制操作或添加截图。"
            case .invalidImage(let name): return "无法读取步骤截图：\(name)"
            }
        }
    }

    private struct Slide: Encodable {
        var id: String
        var image: String
        var title: String
        var body: String
        var hotspot: DemoPoint?
        var nextStepID: String?
    }
    private struct Payload: Encodable {
        var title: String
        var width: Int
        var height: Int
        var steps: [Slide]
    }

    static func html(project: DemoProject, directory: URL) throws -> String {
        try document(project: project, directory: directory, selectedStep: 0, editing: false)
    }

    static func export(project: DemoProject, directory: URL, to destination: URL) throws {
        try html(project: project, directory: directory).write(to: destination, atomically: true, encoding: .utf8)
    }

    // Encoding user strings into an inert Base64 payload also protects closing script tags.
    fileprivate static func encoded(project: DemoProject, directory: URL) throws -> String {
        guard !project.steps.isEmpty else { throw ExportError.noSteps }
        let root = directory.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        var slides: [Slide] = []
        for step in project.steps {
            let file = directory.appendingPathComponent(step.imageName).resolvingSymlinksInPath().standardizedFileURL
            guard file.path.hasPrefix(root),
                  let data = try? Data(contentsOf: file),
                  data.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]) else {
                throw ExportError.invalidImage(step.imageName)
            }
            let point = step.hotspot.map {
                DemoPoint(x: $0.x.isFinite ? min(1, max(0, $0.x)) : 0.5,
                          y: $0.y.isFinite ? min(1, max(0, $0.y)) : 0.5)
            }
            slides.append(Slide(id: step.id, image: "data:image/png;base64," + data.base64EncodedString(),
                                title: step.title, body: step.body, hotspot: point, nextStepID: step.nextStepID))
        }
        let payload = Payload(title: project.title, width: max(1, project.width), height: max(1, project.height), steps: slides)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(payload).base64EncodedString()
    }

    fileprivate static func document(project: DemoProject, directory: URL, selectedStep: Int, editing: Bool) throws -> String {
        let payload = try encoded(project: project, directory: directory)
        return template.replacingOccurrences(of: "__XSHOT_PAYLOAD__", with: payload)
            .replacingOccurrences(of: "__XSHOT_INDEX__", with: String(max(0, min(project.steps.count - 1, selectedStep))))
            .replacingOccurrences(of: "__XSHOT_EDITING__", with: editing ? "true" : "false")
            .replacingOccurrences(of: "__XSHOT_TITLE__", with: escapeHTML(project.title))
    }

    fileprivate static func previewDocument(title: String, update: String) -> String {
        template.replacingOccurrences(of: "window.XShotDemo.load('__XSHOT_PAYLOAD__',__XSHOT_INDEX__,__XSHOT_EDITING__);", with: update)
            .replacingOccurrences(of: "__XSHOT_TITLE__", with: escapeHTML(title))
    }

    private static func escapeHTML(_ string: String) -> String {
        string.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    private static let template = #"""
<!doctype html>
<html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src data:; style-src 'unsafe-inline'; script-src 'unsafe-inline'; connect-src 'none'; base-uri 'none'; form-action 'none'">
<title>__XSHOT_TITLE__</title>
<style>
:root{color-scheme:light dark;font-family:-apple-system,BlinkMacSystemFont,"Helvetica Neue",sans-serif;color:#25272c;background:#f2f3f6;font-size:14px}
*{box-sizing:border-box}body{margin:0}button{font:inherit}button:focus-visible,[tabindex]:focus-visible{outline:3px solid #76a6ff;outline-offset:3px}
.player{width:100%;min-height:100vh;display:flex;flex-direction:column;padding:22px;gap:16px;max-width:1500px;margin:auto}
.heading{display:flex;align-items:center;justify-content:space-between;gap:16px;min-height:24px}.heading h1{font-size:15px;font-weight:600;margin:0;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}.mode{font-size:12px;color:#787d87;flex-shrink:0}
.stage-wrap{flex:1;min-height:0;display:flex;align-items:center;justify-content:center}.stage{position:relative;width:100%;aspect-ratio:16/10;max-height:calc(100vh - 156px);border-radius:12px;overflow:hidden;box-shadow:0 8px 30px #1a253015;border:1px solid #8b919522;background:#e6e8ed;isolation:isolate}
.screen{display:block;width:100%;height:100%;object-fit:contain;background:#e6e8ed;user-select:none;-webkit-user-drag:none}.stage.switching .screen{opacity:.7}.screen{transition:opacity 120ms ease}
.image-plane{position:absolute;pointer-events:none}.hotspot{position:absolute;pointer-events:auto;transform:translate(-50%,-50%);width:44px;height:44px;display:grid;place-items:center;border:0;background:transparent;border-radius:50%;cursor:pointer;padding:0;touch-action:none;z-index:2}.dot{display:block;width:15px;height:15px;border-radius:50%;background:#3478f6;border:3px solid #fff;box-shadow:0 0 0 5px #3478f62b,0 2px 8px #0003}.hotspot:hover .dot{box-shadow:0 0 0 8px #3478f630,0 2px 8px #0003}.hotspot.editing{outline:1px dashed #3478f680;outline-offset:1px;cursor:grab}.hotspot.dragging{cursor:grabbing}.hotspot[hidden],.callout[hidden]{display:none}
.callout{position:absolute;z-index:3;max-width:min(280px,calc(100% - 24px));width:max-content;padding:15px 17px;background:#fff;color:#25272c;border:1px solid #20252c12;border-radius:12px;box-shadow:0 5px 24px #15243a26;pointer-events:none}.callout h2,.description h2{font-size:14px;line-height:1.45;margin:0 0 5px;font-weight:600;white-space:pre-wrap;overflow-wrap:anywhere}.callout p,.description p{font-size:13px;line-height:1.55;margin:0;color:#646b75;white-space:pre-wrap;overflow-wrap:anywhere}.callout:after{content:"";position:absolute;width:9px;height:9px;left:var(--arrow-x,22px);top:-5px;background:#fff;transform:rotate(45deg);border-top:1px solid #20252c12;border-left:1px solid #20252c12}.callout.above:after{top:auto;bottom:-5px;transform:rotate(225deg)}
.description{display:none;padding:0 4px}.description.visible{display:block}.controls{display:flex;align-items:center;gap:14px;min-height:36px}.nav{display:flex;align-items:center;gap:6px}button.control{border:1px solid #747c8926;border-radius:8px;padding:7px 12px;color:inherit;background:#fff;cursor:pointer;min-height:34px}button.control:disabled{opacity:.35;cursor:default}.control.primary{background:#3478f6;color:white;border-color:transparent}.counter{font-size:12px;color:#727984;font-variant-numeric:tabular-nums;min-width:44px;text-align:center}.progress{height:3px;flex:1;background:#747c891f;border-radius:6px;overflow:hidden}.progress span{display:block;height:100%;background:#3478f6;transition:width 180ms ease}.hint{font-size:12px;color:#7d8490;text-align:center;display:none}.empty{margin:auto;color:#747c89}.complete{position:absolute;inset:0;background:#161d2f57;display:flex;align-items:center;justify-content:center;z-index:5}.complete[hidden]{display:none}.complete-card{background:#fff;color:#25272c;border-radius:18px;padding:28px 34px;text-align:center;box-shadow:0 10px 45px #0002}.complete-card h2{margin:0 0 8px;font-size:20px}.complete-card p{margin:0 0 20px;color:#747c89}.complete-card .control{min-width:100px}
@media(min-width:621px){.player.has-description .stage{max-height:calc(100vh - 230px)}}
@media(max-width:620px){.player{padding:12px;gap:12px}.stage{max-height:calc(100vh - 250px);border-radius:9px}.callout{display:none!important}.description{display:block;min-height:54px}.heading h1{font-size:14px}.mode{display:none}.controls{gap:8px}.control{white-space:nowrap}.progress{min-width:12px}.counter{min-width:34px}}
@media(prefers-color-scheme:dark){:root{color:#f0f1f4;background:#202126}.mode,.counter,.hint{color:#a4a8b3}.stage,.screen{background:#303238}.stage{border-color:#fff1}.callout,.complete-card{color:#f0f1f4;background:#303238;border-color:#fff1}.callout:after{background:#303238;border-color:#fff1}.callout p,.description p,.complete-card p{color:#b5bac4}button.control{background:#35383f;border-color:#fff1}.control.primary{background:#3478f6}.progress{background:#ffffff1c}}
@media(prefers-reduced-motion:reduce){*{transition:none!important}}
</style></head><body><main class="player" id="player">
<header class="heading"><h1 id="project-title"></h1><span class="mode" id="mode-label">交互式演示</span></header>
<div class="stage-wrap"><section class="stage" id="stage" aria-label="产品演示截图"><img class="screen" id="screen" alt="" draggable="false"><div class="image-plane" id="plane"><button id="hotspot" class="hotspot" aria-label="点击高亮位置继续"><span class="dot"></span></button></div><article id="callout" class="callout"><h2 id="step-title"></h2><p id="step-body"></p></article><div id="complete" class="complete" hidden><div class="complete-card"><h2>演示完成</h2><p>你已走完这条操作路径</p><button id="restart-end" class="control primary">重新体验</button></div></div></section></div>
<div class="description" id="step-description" aria-live="polite"><h2 id="mobile-title"></h2><p id="mobile-body"></p></div>
<footer class="controls" id="controls"><div class="nav"><button class="control" id="back" aria-label="上一步">←</button><span id="counter" class="counter" aria-live="polite"></span><button class="control primary" id="next">下一步</button></div><div class="progress" role="progressbar" id="progress"><span id="fill"></span></div><button id="restart" class="control" aria-label="从头播放">重播</button></footer>
<div id="edit-hint" class="hint">在截图上点击或拖动圆点，设置这一步的点击位置</div>
</main><script>
'use strict';
(()=>{
let model={steps:[]},index=0,history=[],editing=false,completed=false,drag=null,displayedURI=null,pendingURI=null,preloadedURI=null;
const imageBank=new Map();
const $=id=>document.getElementById(id),stage=$('stage'),screen=$('screen'),plane=$('plane'),hotspot=$('hotspot'),callout=$('callout');
const decode=encoded=>JSON.parse(new TextDecoder().decode(Uint8Array.from(atob(encoded),c=>c.charCodeAt(0))));
const clamp=n=>Number.isFinite(n)?Math.max(0,Math.min(1,n)):.5;
function current(){return model.steps[index]}
function destination(){const s=current();if(!s)return -1;if(s.nextStepID){const target=model.steps.findIndex(x=>x.id===s.nextStepID);if(target>=0)return target;}return index+1<model.steps.length?index+1:-1;}
function setText(id,text){$(id).textContent=text||''}
function geometry(){const r=stage.getBoundingClientRect(),w=screen.naturalWidth||model.width||1,h=screen.naturalHeight||model.height||1,scale=Math.min(r.width/w,r.height/h),pw=w*scale,ph=h*scale;Object.assign(plane.style,{left:((r.width-pw)/2)+'px',top:((r.height-ph)/2)+'px',width:pw+'px',height:ph+'px'});place();}
function place(){const s=current();if(!s)return;const p=s.hotspot||{x:.5,y:.5};hotspot.style.left=(clamp(p.x)*100)+'%';hotspot.style.top=(clamp(p.y)*100)+'%';if(callout.hidden)return;const pr=plane.getBoundingClientRect(),sr=stage.getBoundingClientRect(),x=pr.left-sr.left+clamp(p.x)*pr.width,y=pr.top-sr.top+clamp(p.y)*pr.height;callout.classList.remove('above');callout.style.left='12px';callout.style.top='12px';const cr=callout.getBoundingClientRect(),left=Math.max(12,Math.min(sr.width-cr.width-12,x-cr.width/2));let top=y+27;if(top+cr.height>sr.height-12){top=y-cr.height-27;callout.classList.add('above');}top=Math.max(12,Math.min(sr.height-cr.height-12,top));callout.style.left=left+'px';callout.style.top=top+'px';callout.style.setProperty('--arrow-x',Math.max(14,Math.min(cr.width-22,x-left-5))+'px');}
function render(keepCompleted=false){const s=current();if(!s)return;completed=keepCompleted;$('complete').hidden=!completed;setText('project-title',model.title||'产品演示');setText('step-title',s.title);setText('step-body',s.body);setText('mobile-title',s.title);setText('mobile-body',s.body);setText('counter',(index+1)+' / '+model.steps.length);setText('mode-label',editing?'编辑点击位置':'交互式演示');setText('next',destination()<0?'完成':'下一步');$('back').disabled=history.length===0;$('progress').setAttribute('aria-valuemin','0');$('progress').setAttribute('aria-valuemax',String(model.steps.length));$('progress').setAttribute('aria-valuenow',String(index+1));$('fill').style.width=((index+1)/model.steps.length*100)+'%';$('edit-hint').style.display=editing?'block':'none';hotspot.classList.toggle('editing',editing);hotspot.hidden=!s.hotspot&&!editing;hotspot.setAttribute('aria-label',editing?'拖动设置点击位置':s.title||'点击高亮位置继续');callout.hidden=editing||!s.hotspot||!(s.title||s.body);stage.style.cursor=editing?'crosshair':'default';screen.alt=s.title||'第 '+(index+1)+' 步';
$('controls').style.display=editing?'none':'flex';$('step-description').classList.toggle('visible',!s.hotspot&&!editing);$('player').classList.toggle('has-description',!s.hotspot&&!editing);
if(displayedURI===s.image){geometry();}else if(pendingURI!==s.image){const uri=s.image;pendingURI=uri;const img=new Image();stage.classList.add('switching');img.onload=()=>{if(pendingURI!==uri||current()?.image!==uri)return;screen.src=uri;displayedURI=uri;pendingURI=null;geometry();stage.classList.remove('switching');};img.onerror=()=>{if(pendingURI===uri){pendingURI=null;stage.classList.remove('switching');}};img.src=uri;}const target=destination();if(target>=0&&preloadedURI!==model.steps[target].image){preloadedURI=model.steps[target].image;const preload=new Image();preload.src=preloadedURI;}requestAnimationFrame(place);}
function next(){if(editing||completed)return;const target=destination();if(target<0){completed=true;$('complete').hidden=false;$('restart-end').focus();return;}history.push(index);index=target;render();}
function back(){if(completed){completed=false;$('complete').hidden=true;return;}if(history.length){index=history.pop();render();}}
function restart(){history=[];index=0;render();}
function point(event){const r=plane.getBoundingClientRect();return{x:clamp((event.clientX-r.left)/r.width),y:clamp((event.clientY-r.top)/r.height)}}
function move(event,notify){const s=current();if(!s)return;s.hotspot=point(event);place();if(notify&&window.webkit&&window.webkit.messageHandlers&&window.webkit.messageHandlers.xshotHotspot){window.webkit.messageHandlers.xshotHotspot.postMessage({stepID:s.id,x:s.hotspot.x,y:s.hotspot.y});}}
hotspot.addEventListener('click',event=>{event.stopPropagation();if(!editing)next()});
stage.addEventListener('pointerdown',event=>{if(!editing||event.button!==0)return;const r=plane.getBoundingClientRect();if(event.clientX<r.left||event.clientX>r.right||event.clientY<r.top||event.clientY>r.bottom)return;drag=event.pointerId;stage.setPointerCapture(drag);hotspot.classList.add('dragging');move(event,false);event.preventDefault();});
stage.addEventListener('pointermove',event=>{if(editing&&drag===event.pointerId)move(event,false)});
function finishDrag(event){if(drag!==event.pointerId)return;move(event,true);drag=null;hotspot.classList.remove('dragging');}
stage.addEventListener('pointerup',finishDrag);stage.addEventListener('pointercancel',()=>{drag=null;hotspot.classList.remove('dragging')});
$('next').addEventListener('click',next);$('back').addEventListener('click',back);$('restart').addEventListener('click',restart);$('restart-end').addEventListener('click',restart);
document.addEventListener('keydown',event=>{if(editing||event.metaKey||event.ctrlKey||event.altKey)return;if(event.key==='ArrowRight'){event.preventDefault();next();}if(event.key==='ArrowLeft'){event.preventDefault();back();}});
new ResizeObserver(geometry).observe(stage);
window.XShotDemo={load(encoded,start,isEditing){model=decode(encoded);editing=!!isEditing;index=Math.max(0,Math.min(model.steps.length-1,Number(start)||0));history=[];render();},update(metadata,images,start,isEditing,select,reset){const oldID=current()?.id,oldHistory=history.map(i=>model.steps[i]?.id),wasCompleted=completed;if(reset)imageBank.clear();if(images){for(const [name,uri] of Object.entries(decode(images)))imageBank.set(name,uri);}model=decode(metadata);model.steps=model.steps.map(step=>({...step,image:imageBank.get(step.imageName)}));editing=!!isEditing;const retained=model.steps.findIndex(step=>step.id===oldID);if(select||reset){index=Math.max(0,Math.min(model.steps.length-1,Number(start)||0));history=[];}else{index=retained>=0?retained:Math.max(0,Math.min(model.steps.length-1,Number(start)||0));history=oldHistory.map(id=>model.steps.findIndex(step=>step.id===id)).filter(i=>i>=0);}render(!select&&!reset&&retained>=0&&wasCompleted);},state(){return{index,history:[...history],completed,destination:destination()};},next,back,restart};
window.XShotDemo.load('__XSHOT_PAYLOAD__',__XSHOT_INDEX__,__XSHOT_EDITING__);
})();
</script></body></html>
"""#
}

final class InteractiveDemoPreview: NSView, WKScriptMessageHandler, WKNavigationDelegate {
    var onHotspotMoved: ((DemoPoint) -> Void)?
    private var webView: WKWebView!
    private var ready = false
    private var pendingUpdate: (InteractiveDemoPreviewCache.Update, Int, Bool, Bool)?
    private var loaded = false
    private var currentStepID: String?
    private var isEditing = false
    private var lastRequestedStepID: String?
    private var lastRequestedEditing: Bool?
    private let imageCache = InteractiveDemoPreviewCache()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.add(WeakHotspotHandler(self), name: "xshotHotspot")
        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.setValue(false, forKey: "drawsBackground")
        addSubview(webView)
        NSLayoutConstraint.activate([webView.leadingAnchor.constraint(equalTo: leadingAnchor),
                                     webView.trailingAnchor.constraint(equalTo: trailingAnchor),
                                     webView.topAnchor.constraint(equalTo: topAnchor),
                                     webView.bottomAnchor.constraint(equalTo: bottomAnchor)])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show(project: DemoProject, directory: URL, selectedStep: Int, editing: Bool) {
        let selected = max(0, min(project.steps.count - 1, selectedStep))
        currentStepID = project.steps.indices.contains(selected) ? project.steps[selected].id : nil
        isEditing = editing
        do {
            let patch = try imageCache.update(project: project, directory: directory)
            let select = patch.reset || lastRequestedStepID != currentStepID || lastRequestedEditing != editing
            lastRequestedStepID = currentStepID
            lastRequestedEditing = editing
            if loaded {
                if ready { apply(patch, selected: selected, editing: editing, select: select) }
                else { pendingUpdate = (patch, selected, editing, select || pendingUpdate?.3 == true) }
            } else {
                loaded = true
                ready = false
                imageCache.didSend(patch)
                webView.loadHTMLString(InteractiveDemoExporter.previewDocument(title: project.title,
                    update: patch.javaScript(selected: selected, editing: editing, select: true)), baseURL: nil)
            }
        } catch {
            loaded = false
            ready = false
            pendingUpdate = nil
            imageCache.resetBrowser()
            let message = error.localizedDescription.replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
            webView.loadHTMLString("<html><meta charset='utf-8'><body style='font:14px -apple-system;color:#777;display:grid;place-items:center;height:90vh'>\(message)</body></html>", baseURL: nil)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        ready = true
        if let (patch, selected, editing, select) = pendingUpdate {
            pendingUpdate = nil
            apply(patch, selected: selected, editing: editing, select: select)
        }
    }

    private func apply(_ patch: InteractiveDemoPreviewCache.Update, selected: Int, editing: Bool, select: Bool) {
        imageCache.didSend(patch)
        webView.evaluateJavaScript(patch.javaScript(selected: selected, editing: editing, select: select))
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        // The player is a complete local document; it never needs to navigate out.
        decisionHandler(navigationAction.request.url?.scheme == "about" ? .allow : .cancel)
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard isEditing, message.name == "xshotHotspot", let body = message.body as? [String: Any],
              body["stepID"] as? String == currentStepID,
              let x = body["x"] as? Double, let y = body["y"] as? Double, x.isFinite, y.isFinite else { return }
        onHotspotMoved?(DemoPoint(x: x, y: y).clamped)
    }

    private final class WeakHotspotHandler: NSObject, WKScriptMessageHandler {
        weak var owner: InteractiveDemoPreview?
        init(_ owner: InteractiveDemoPreview) { self.owner = owner }
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            owner?.userContentController(userContentController, didReceive: message)
        }
    }
}

/// PNGs are immutable project assets. Keep one data URI per file, independently
/// of undo snapshots; routine text/hotspot edits only encode small metadata.
final class InteractiveDemoPreviewCache {
    struct Update {
        var metadata: String
        var images: String
        var imageNames: [String]
        var reset: Bool
        func javaScript(selected: Int, editing: Bool, select: Bool) -> String {
            "window.XShotDemo.update('\(metadata)','\(images)',\(selected),\(editing ? "true" : "false"),\(select ? "true" : "false"),\(reset ? "true" : "false"));"
        }
    }
    private struct Metadata: Encodable {
        var title: String
        var width: Int
        var height: Int
        var steps: [Step]
    }
    private struct Step: Encodable {
        var id: String
        var imageName: String
        var title: String
        var body: String
        var hotspot: DemoPoint?
        var nextStepID: String?
    }
    private var directoryPath: String?
    private var resolvedDirectory: URL?
    private var imagesByName: [String: String] = [:]
    private var sentNames: Set<String> = []
    private var needsReset = true
    private(set) var imageReadCount = 0

    func update(project: DemoProject, directory: URL) throws -> Update {
        guard !project.steps.isEmpty else { throw InteractiveDemoExporter.ExportError.noSteps }
        let path = directory.standardizedFileURL.path
        if directoryPath != path {
            directoryPath = path
            resolvedDirectory = directory.resolvingSymlinksInPath().standardizedFileURL
            imagesByName.removeAll(); sentNames.removeAll(); needsReset = true
        }
        var newImages: [String: String] = [:]
        let root = resolvedDirectory!.path + "/"
        for name in Set(project.steps.map(\.imageName)) {
            if imagesByName[name] == nil {
                let file = resolvedDirectory!.appendingPathComponent(name).resolvingSymlinksInPath().standardizedFileURL
                guard file.path.hasPrefix(root), let data = try? Data(contentsOf: file),
                      data.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]) else {
                    throw InteractiveDemoExporter.ExportError.invalidImage(name)
                }
                imageReadCount += 1
                imagesByName[name] = "data:image/png;base64," + data.base64EncodedString()
            }
            if !sentNames.contains(name) { newImages[name] = imagesByName[name] }
        }
        let steps = project.steps.map { step in
            Step(id: step.id, imageName: step.imageName, title: step.title, body: step.body,
                 hotspot: step.hotspot.map { DemoPoint(x: $0.x.isFinite ? min(1, max(0, $0.x)) : 0.5,
                                                       y: $0.y.isFinite ? min(1, max(0, $0.y)) : 0.5) },
                 nextStepID: step.nextStepID)
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let metadata = try encoder.encode(Metadata(title: project.title, width: max(1, project.width),
                                                  height: max(1, project.height), steps: steps)).base64EncodedString()
        // An empty image patch never visits any PNG or serializes cached image strings.
        let imagePatch = newImages.isEmpty ? "" : try encoder.encode(newImages).base64EncodedString()
        return Update(metadata: metadata, images: imagePatch, imageNames: Array(newImages.keys), reset: needsReset)
    }

    func didSend(_ update: Update) {
        sentNames.formUnion(update.imageNames)
        needsReset = false
    }

    func resetBrowser() { sentNames.removeAll(); needsReset = true }
}
