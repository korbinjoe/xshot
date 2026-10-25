import AppKit

@main struct InteractiveDemoChecks {
    static func main() throws {
        let destination = CommandLine.arguments.dropFirst().first ?? NSTemporaryDirectory() + "xshot-interactive-checks"
        let directory = URL(fileURLWithPath: destination, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 640, pixelsHigh: 400,
                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                      isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let context = NSGraphicsContext(bitmapImageRep: bitmap)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSColor(calibratedRed: 0.94, green: 0.96, blue: 0.99, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: 640, height: 400).fill()
        NSColor.systemBlue.setFill()
        NSBezierPath(roundedRect: NSRect(x: 440, y: 245, width: 150, height: 55), xRadius: 10, yRadius: 10).fill()
        ("XShot 步骤演示" as NSString).draw(at: NSPoint(x: 35, y: 330), withAttributes: [
            .font: NSFont.systemFont(ofSize: 25, weight: .semibold), .foregroundColor: NSColor.labelColor])
        NSGraphicsContext.restoreGraphicsState()
        let png = bitmap.representation(using: .png, properties: [:])!
        try png.write(to: directory.appendingPathComponent("fixture.png"))

        let attack = "</script><script>globalThis.hacked=true</script><img src=x onerror=alert(1)> & \" 中文"
        var project = DemoProject()
        project.title = "中文演示 " + attack
        project.width = 640
        project.height = 400
        project.steps = [
            DemoStep(id: "start", imageName: "fixture.png", title: "点击开始", body: attack,
                     hotspot: DemoPoint(x: -4, y: 3), nextStepID: "result"),
            DemoStep(id: "skip", imageName: "fixture.png", title: "可选步骤", hotspot: nil),
            DemoStep(id: "result", imageName: "fixture.png", title: "完成设置", body: "这是最终结果。\n支持中文换行。",
                     hotspot: DemoPoint(x: .infinity, y: .nan))
        ]
        let html = try InteractiveDemoExporter.html(project: project, directory: directory)
        precondition(!html.contains(attack), "User text escaped out of the inert payload")
        precondition(html.contains("&lt;/script&gt;"), "Document title was not HTML escaped")
        precondition(!html.contains("https://") && !html.contains("http://"), "Player contains a network reference")
        precondition(html.contains("connect-src 'none'"), "Network connections not blocked")
        let prefix = "window.XShotDemo.load('"
        let encoded = String(html.components(separatedBy: prefix).last!.prefix { $0 != "'" })
        let data = Data(base64Encoded: encoded)!
        let payload = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        precondition(payload["title"] as? String == project.title, "Unicode title changed")
        let steps = payload["steps"] as! [[String: Any]]
        precondition(steps[0]["body"] as? String == attack, "User text did not round trip")
        let firstPoint = steps[0]["hotspot"] as! [String: Double]
        precondition(firstPoint["x"] == 0 && firstPoint["y"] == 1, "Hotspot boundary clamping failed")
        let finitePoint = steps[2]["hotspot"] as! [String: Double]
        precondition(finitePoint["x"] == 0.5 && finitePoint["y"] == 0.5, "Nonfinite coordinates broke serialization")
        let embedded = steps[0]["image"] as! String
        precondition(Data(base64Encoded: String(embedded.dropFirst("data:image/png;base64,".count))) == png,
                     "Embedded screenshot bytes changed")
        try InteractiveDemoExporter.export(project: project, directory: directory, to: directory.appendingPathComponent("fixture.html"))
        let exported = try String(contentsOf: directory.appendingPathComponent("fixture.html"), encoding: .utf8)
        precondition(exported == html)

        var invalid = project
        invalid.steps[0].imageName = "../../outside.png"
        do { _ = try InteractiveDemoExporter.html(project: invalid, directory: directory); fatalError("Path traversal accepted") }
        catch is InteractiveDemoExporter.ExportError { }
        invalid.steps = []
        do { _ = try InteractiveDemoExporter.html(project: invalid, directory: directory); fatalError("Empty demo accepted") }
        catch is InteractiveDemoExporter.ExportError { }

        let cache = InteractiveDemoPreviewCache()
        let initialPatch = try cache.update(project: project, directory: directory)
        cache.didSend(initialPatch)
        precondition(cache.imageReadCount == 1, "Shared screenshots read more than once")
        try FileManager.default.removeItem(at: directory.appendingPathComponent("fixture.png"))
        var edited = project
        for index in 0..<80 {
            edited.title = "第 \(index) 次中文编辑"
            edited.steps[0].body = "编辑内容 \(index) " + attack
            edited.steps[0].hotspot = DemoPoint(x: Double(index) / 80, y: 0.2)
            let patch = try cache.update(project: edited, directory: directory)
            precondition(patch.images.isEmpty && patch.imageNames.isEmpty && !patch.reset,
                         "A metadata edit retransmitted PNG data")
            cache.didSend(patch)
        }
        precondition(cache.imageReadCount == 1, "Text/hotspot edits accessed screenshots")
        try png.write(to: directory.appendingPathComponent("fixture.png"))
        try png.write(to: directory.appendingPathComponent("replacement.png"))
        edited.steps[0].imageName = "replacement.png"
        let replacement = try cache.update(project: edited, directory: directory)
        precondition(replacement.imageNames == ["replacement.png"] && cache.imageReadCount == 2,
                     "New image did not produce a single asset delta")
        cache.didSend(replacement)
        let undone = try cache.update(project: project, directory: directory)
        precondition(undone.images.isEmpty && cache.imageReadCount == 2, "Undo reread cached screenshot")

        let script = html.components(separatedBy: "<script>\n")[1].components(separatedBy: "</script>")[0]
        let testScript = domStub + "\n" + script + #"""
        const check=(value,message)=>{if(!value)throw new Error(message)};
        let state=XShotDemo.state();check(state.index===0&&state.destination===2,'branch target failed');
        elements.get('hotspot').listeners.click({stopPropagation(){}});check(XShotDemo.state().index===2,'hotspot did not branch');
        elements.get('back').listeners.click();check(XShotDemo.state().index===0,'back lost actual branch history');
        XShotDemo.next();XShotDemo.next();check(XShotDemo.state().completed,'last step did not finish');
        XShotDemo.back();check(!XShotDemo.state().completed&&XShotDemo.state().index===2,'back from completion failed');
        XShotDemo.restart();check(XShotDemo.state().index===0&&XShotDemo.state().history.length===0,'restart failed');
        check(globalThis.hacked===undefined,'user text executed');
        const first=JSON.parse(new TextDecoder().decode(Uint8Array.from(atob('__ENCODED__'),c=>c.charCodeAt(0))));
        first.steps[0].nextStepID='missing';const encoded=Buffer.from(JSON.stringify(first)).toString('base64');
        XShotDemo.load(encoded,0,false);check(XShotDemo.state().destination===1,'broken branch did not fall back');
        XShotDemo.load(encoded,0,true);XShotDemo.next();check(XShotDemo.state().index===0,'editing advanced playback');
        let moved;window.webkit={messageHandlers:{xshotHotspot:{postMessage(value){moved=value}}}};
        const surface=elements.get('stage'),pointer={button:0,pointerId:7,clientX:300,clientY:200,preventDefault(){}};
        surface.listeners.pointerdown(pointer);surface.listeners.pointermove({...pointer,clientX:1000,clientY:-200});
        surface.listeners.pointerup({...pointer,clientX:1000,clientY:-200});
        check(moved.stepID==='start'&&moved.x===1&&moved.y===0,'edit drag did not normalize or clamp');
        XShotDemo.update('__META__','__IMAGES__',0,false,true,true);XShotDemo.next();
        let metadata=JSON.parse(new TextDecoder().decode(Uint8Array.from(atob('__META__'),c=>c.charCodeAt(0))));
        const beforeLoads=globalThis.imageLoads;
        for(let i=0;i<80;i++){metadata.title='编辑 '+i;metadata.steps[2].body='新说明 '+i;
          XShotDemo.update(Buffer.from(JSON.stringify(metadata)).toString('base64'),'',0,false,false,false);}
        check(XShotDemo.state().index===2&&XShotDemo.state().history[0]===0,'metadata edit reset playback history');
        check(elements.get('step-body').textContent==='新说明 79','metadata did not update visible text');
        check(globalThis.imageLoads===beforeLoads,'metadata edit decoded screenshot again');
        metadata.steps=[metadata.steps[2],metadata.steps[0],metadata.steps[1]];
        XShotDemo.update(Buffer.from(JSON.stringify(metadata)).toString('base64'),'',0,false,false,false);
        check(XShotDemo.state().index===0&&XShotDemo.state().history[0]===1,'reordering lost step identity/history');
        XShotDemo.back();check(XShotDemo.state().index===1,'history back after reorder failed');
        metadata.steps[1].hotspot=null;
        XShotDemo.update(Buffer.from(JSON.stringify(metadata)).toString('base64'),'',1,false,true,false);
        check(elements.get('step-description').classList.contains('visible'),'result step hid its description on desktop');
        metadata.steps[1].hotspot={x:.5,y:.5};
        XShotDemo.update(Buffer.from(JSON.stringify(metadata)).toString('base64'),'',1,false,false,false);
        check(!elements.get('step-description').classList.contains('visible'),'hotspot step duplicated its callout');
        console.log('PASS actual player JS: hotspot, branch, history, completion, replay, edit drag, incremental metadata, XSS');
        """#.replacingOccurrences(of: "__ENCODED__", with: encoded)
            .replacingOccurrences(of: "__META__", with: initialPatch.metadata)
            .replacingOccurrences(of: "__IMAGES__", with: initialPatch.images)
        let js = directory.appendingPathComponent("player-check.cjs")
        try testScript.write(to: js, atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["node", js.path]
        try process.run()
        process.waitUntilExit()
        precondition(process.terminationStatus == 0, "Player JS checks failed")
        print("PASS independent HTML: Chinese text, hostile text, PNG integrity, coordinates, offline CSP, invalid paths, export")
        print("PASS preview cache: 80 metadata edits without image access, single replacement delta, cached undo")
        print("Public test fixture: \(directory.appendingPathComponent("fixture.html").path)")
    }

    // This checks the real navigation code without introducing a browser or test dependency.
    // Real layout, native input and drag behavior still require the app/browser validation pass.
    static let domStub = #"""
    globalThis.window=globalThis;
    const elements=new Map();
    const element=id=>({id,style:{setProperty(){}},hidden:false,disabled:false,src:'',naturalWidth:640,naturalHeight:400,listeners:{},
      classList:{values:new Set(),add(name){this.values.add(name)},remove(name){this.values.delete(name)},
        toggle(name,on){if(on)this.values.add(name);else this.values.delete(name)},contains(name){return this.values.has(name)}},
      textContent:'',setAttribute(){},addEventListener(type,callback){this.listeners[type]=callback},focus(){},
      getBoundingClientRect(){return {left:0,top:0,right:640,bottom:400,width:640,height:400}},setPointerCapture(){}});
    globalThis.document={getElementById(id){if(!elements.has(id))elements.set(id,element(id));return elements.get(id)},addEventListener(){}};
    globalThis.requestAnimationFrame=callback=>callback();
    globalThis.ResizeObserver=class{constructor(callback){}observe(){}};
    globalThis.imageLoads=0;
    globalThis.Image=class{set src(value){globalThis.imageLoads++;this.value=value;if(this.onload)this.onload()}get src(){return this.value}};
    """#
}
