import Foundation

enum DYForwardConversation {
    /// Resolve by canonical user/group identity, never by display name or row order.
    /// Opening a conversation is read-only; this code has no send operation.
    static let resolveJS = #"""
    const uid = recipient.startsWith(kind + '|') ? recipient.slice(2) : '';
    if (!uid || ![1,2].includes(kind)) return null;
    const identity = value => typeof value === 'string' ? value :
      typeof value === 'number' && Number.isSafeInteger(value) ? String(value) : null;
    const matches = c => c && Number(c.type) === kind && (kind === 1
      ? identity(c.toParticipantUserId) === uid || (!!secUid && c.toParticipantSecUserId === secUid)
      : identity(c.shortId) === uid || identity(c.id) === uid);
    const official = window.__ddOfficialIM?.();
    if (official?.adapter) {
      try {
        const target = kind === 1 ? {participantId: uid} : {conversationShortId: uid};
        const conversation = await official.adapter.getConversationByIdWithOnlineAsync(target);
        if (matches(conversation)) {
          await official.adapter.openConversation({...(kind === 1 ? {uid} : {conversationId: uid}),
            conversationType: kind, enterMethod: 'share_board'});
        }
      } catch (_) {}
    }
    const find = () => {
      const found = [];
      for (const e of document.querySelectorAll('[data-e2e="conversation-item"]')) {
        let f = e[Object.keys(e).find(key => key.startsWith('__reactFiber'))], c;
        for (let i=0; f && i<8; i++, f=f.return) {
          if (f.memoizedProps?.conversation) { c=f.memoizedProps.conversation; break; }
        }
        if (!matches(c) || !identity(c.id)) continue;
        const text = selector => e.querySelector(selector)?.textContent?.trim() || '';
        const flame = e.querySelector('[class*="commonStreakstreakContainer"]');
        found.push({id:'conversation:' + identity(c.id), name:text('[class="conversationConversationItemtitle"]') || name,
          avatar:e.querySelector('img')?.src || avatar || null, preview:text('[class*="HinttextBox"]'),
          time:text('[class*="timeStr"]'), badge:'', index:'0', stranger:!!e.closest('[class*="StrangerConversationList"]'),
          kind, sec:c.toParticipantSecUserId || secUid || null,
          streak:flame ? {text:flame.textContent.trim(),icon:flame.querySelector('img')?.src || null} : null,
          isPinned:String(e.className || '').includes('isStickOnTop')});
      }
      return found.length === 1 ? found[0] : null;
    };
    for (let attempt=0; attempt<25; attempt++) {
      const row = find();
      if (row) return JSON.stringify(row);
      await new Promise(resolve => setTimeout(resolve,200));
    }
    return null;
    """#
}
