import { EditorState, Compartment, Transaction } from '@codemirror/state';
import { EditorView, Decoration, ViewPlugin, WidgetType, keymap, drawSelection } from '@codemirror/view';
import { history, historyKeymap, defaultKeymap, indentWithTab, undo, redo } from '@codemirror/commands';
import { markdown } from '@codemirror/lang-markdown';
import { syntaxTree, syntaxHighlighting, defaultHighlightStyle, HighlightStyle } from '@codemirror/language';
import { tags } from '@lezer/highlight';

const previewMode = new Compartment();
const languageMode = new Compartment();
let view, markdownDocument = true, source = false, loading = false;
const editorHighlightStyle = HighlightStyle.define(defaultHighlightStyle.specs.map(style =>
  style.tag === tags.heading ? {...style, textDecoration:'none'} : style));
function bridge(name, data) {
  if (window.flutter_inappwebview) return window.flutter_inappwebview.callHandler(name, data);
  return Promise.resolve(null);
}

class LocalImage extends WidgetType {
  constructor(source,alt){super();this.source=source;this.alt=alt;}
  eq(other){return other.source===this.source && other.alt===this.alt;}
  toDOM(view){
    const holder=document.createElement('span');
    holder.textContent=this.alt||'正在读取图片…';
    bridge('editorImage',{path:this.source}).then(result=>{
      if(!result?.data){holder.textContent=`[图片未就绪：${this.alt||this.source}]`;return;}
      const image=document.createElement('img');image.className='qj-preview-image';
      image.onload=()=>view.requestMeasure();
      image.alt=this.alt;image.src=`data:${result.mime};base64,${result.data}`;
      holder.replaceChildren(image);
    }).catch(()=>{holder.textContent='[图片暂时无法读取]';});
    return holder;
  }
  ignoreEvent(){return false;}
}

function decorations(view) {
  if (source || !markdownDocument) return Decoration.none;
  const ranges = [];
  for (const visible of view.visibleRanges) {
    syntaxTree(view.state).iterate({ from: visible.from, to: visible.to, enter(node) {
      const name = node.name;
      const line = view.state.doc.lineAt(node.from);
      const editing = view.hasFocus && view.state.selection.ranges.some(range =>
        range.from <= line.to && range.to >= line.from);
      if(name==='Image' && !editing && !view.composing && node.to<=line.to){
        const raw=view.state.sliceDoc(node.from,node.to);
        const match=/^!\[([^\]]*)\]\(<?([^\s>)]+)>?(?:\s+"[^"]*")?\)$/.exec(raw);
        if(match){ranges.push(Decoration.replace({widget:new LocalImage(match[2],match[1])}).range(node.from,node.to));return false;}
      }
      if (/^ATXHeading[1-6]$/.test(name)) {
        ranges.push(Decoration.line({class:`qj-heading qj-h${Math.min(3, +name.at(-1))}`}).range(line.from));
        if (!editing && !view.composing) {
          const hidden = [];
          for (const mark of node.node.getChildren('HeaderMark')) {
            if (mark.from === node.from) {
              const spacing = view.state.sliceDoc(mark.to, line.to).match(/^[ \t]*/)[0].length;
              hidden.push({from:line.from,to:mark.to+spacing});
            } else {
              const spacing = view.state.sliceDoc(node.from, mark.from).match(/[ \t]*$/)[0].length;
              hidden.push({from:mark.from-spacing,to:line.to});
            }
          }
          // Opening and closing marks can overlap in an empty heading (# ###).
          const merged = [];
          for (const range of hidden.sort((a,b)=>a.from-b.from)) {
            const previous = merged.at(-1);
            if (previous && range.from <= previous.to) previous.to = Math.max(previous.to,range.to);
            else merged.push({...range});
          }
          for (const range of merged) ranges.push(Decoration.replace({}).range(range.from,range.to));
        }
      }
      const cls = { StrongEmphasis:'qj-strong', Emphasis:'qj-em', InlineCode:'qj-code', Link:'qj-link' }[name];
      if (cls) ranges.push(Decoration.mark({class:cls}).range(node.from,node.to));
      if (name === 'Blockquote' && node.from === line.from) ranges.push(Decoration.line({class:'qj-quote'}).range(line.from));
      if (name === 'HorizontalRule') ranges.push(Decoration.line({class:'qj-rule'}).range(line.from));
      if (['HeaderMark','EmphasisMark','CodeMark','QuoteMark'].includes(name) &&
          !(name === 'HeaderMark' && /^ATXHeading[1-6]$/.test(node.node.parent?.name ?? '')) &&
          !editing && !view.composing) {
        ranges.push(Decoration.replace({}).range(node.from,node.to));
      }
    }});
  }
  return Decoration.set(ranges,true);
}
const livePreview = ViewPlugin.fromClass(class {
  constructor(view) { this.decorations = decorations(view); }
  update(update) {
    if (update.docChanged || update.selectionSet || update.viewportChanged || update.focusChanged ||
        syntaxTree(update.startState) !== syntaxTree(update.state) || update.transactions.some(t=>t.reconfigured))
      this.decorations = decorations(update.view);
  }
}, {decorations: v=>v.decorations});

function changed(update) {
  if (update.docChanged && !loading) {
    bridge('editorChange',{text:update.state.doc.toString(),composing:update.view.composing});
  }
}
function load({text='', markdown:md=true, source:src=false}) {
  // Status refreshes must keep the editable DOM, selection, focus and history.
  if (view) {
    const effects=[];
    if (markdownDocument!==md) effects.push(languageMode.reconfigure(md?markdown():[]));
    if (markdownDocument!==md || source!==src) effects.push(previewMode.reconfigure(livePreview));
    markdownDocument=md; source=src;
    if (text===view.state.doc.toString() && !effects.length) return;
    loading=true;
    try {
      const transaction={effects,annotations:Transaction.addToHistory.of(false)};
      if (text!==view.state.doc.toString()) {
        transaction.changes={from:0,to:view.state.doc.length,insert:text};
        const {anchor,head}=view.state.selection.main;
        transaction.selection={anchor:Math.min(anchor,text.length),head:Math.min(head,text.length)};
      }
      view.dispatch(transaction);
    } finally { loading=false; }
    return;
  }
  loading = true; markdownDocument=md; source=src;
  view = new EditorView({parent:document.getElementById('editor'),state:EditorState.create({doc:text,extensions:[
    history(), drawSelection(), EditorView.lineWrapping,
    keymap.of([...defaultKeymap,...historyKeymap,indentWithTab]),
    languageMode.of(md?markdown():[]), syntaxHighlighting(editorHighlightStyle),
    previewMode.of(livePreview), EditorView.updateListener.of(changed),
    EditorView.domEventHandlers({compositionend(){
      queueMicrotask(()=>bridge('editorChange',{text:view.state.doc.toString(),composing:false}));
    },blur(){bridge('editorBlur',{});}}),
  ]})});
  // Opening a document starts in preview, including Android WebViews that
  // restore an editable element's focus while loading a page.
  view.contentDOM.blur();
  document.getElementById('loading').style.display='none';
  loading=false;
}
function configure({margins=true}={}) {
  if (document.body.dataset.margins===String(margins)) return;
  document.body.dataset.margins=String(margins);
  // Explicitly refresh the selection layer: CSS can move the text without
  // changing the outer editor width or the current document selection.
  if (view) view.dispatch({selection:view.state.selection,
    annotations:Transaction.addToHistory.of(false)});
  view?.requestMeasure();
}
function replaceSelection(before,after='') {
  const {from,to}=view.state.selection.main;
  const selected=view.state.sliceDoc(from,to);
  view.dispatch({changes:{from,to,insert:before+selected+after},selection:{anchor:from+before.length,head:to+before.length},scrollIntoView:true});
  view.focus();
}
function prefixLines(prefix) {
  const {from,to}=view.state.selection.main;
  const first=view.state.doc.lineAt(from),last=view.state.doc.lineAt(to);
  const changes=[];
  for(let n=first.number;n<=last.number;n++) changes.push({from:view.state.doc.line(n).from,insert:prefix});
  const changeSet=view.state.changes(changes);
  view.dispatch({changes:changeSet,selection:view.state.selection.map(changeSet,1)});view.focus();
}
function command(name) {
  if(!view || view.composing) return;
  const wraps={bold:['**','**'],italic:['*','*'],code:['`','`'],link:['[','](https://)'],image:['![','](image.png)']};
  const prefixes={heading:'# ',list:'- ',ordered:'1. ',task:'- [ ] ',quote:'> '};
  if(wraps[name]) replaceSelection(...wraps[name]);
  else if(prefixes[name]) prefixLines(prefixes[name]);
  else if(name==='undo') undo(view);
  else if(name==='redo') redo(view);
  else if(name==='source'){source=!source;view.dispatch({effects:previewMode.reconfigure(livePreview)});}
}
window.leafmesh={load,configure,command,text:()=>view?.state.doc.toString()??'',focus:()=>view?.focus(),build:window.LEAFMESH_EDITOR_BUILD};
