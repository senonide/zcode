/* LSP-backed completion for the source view.
 *
 * GtkSourceView already owns the popup, filtering and keyboard handling through
 * GtkSourceCompletion; we only implement a provider that asks the language
 * server (in Zig) for proposals.  The async LSP round-trip maps cleanly onto the
 * provider's populate_async / populate_finish pair via a GTask.
 *
 * Two GObjects live here: ZcLspProposal (one completion item) and
 * ZcLspCompletionProvider (the provider added to each view's completion).  Zig
 * builds the proposal list through the zc_completion_store_* helpers and hands
 * the finished GListModel back to the GTask with zc_completion_finish. */

#include "zc_internal.h"

/* ── ZcLspProposal: one completion item ──────────────────────────────────── */

struct _ZcLspProposal {
    GObject parent_instance;
    char   *label;       /* shown + used for filtering */
    char   *detail;      /* type/signature, shown dimmed */
    char   *insert_text; /* applied on activate */
};

static void zc_lsp_proposal_iface_init(GtkSourceCompletionProposalInterface *iface);

G_DEFINE_FINAL_TYPE_WITH_CODE(
    ZcLspProposal, zc_lsp_proposal, G_TYPE_OBJECT,
    G_IMPLEMENT_INTERFACE(GTK_SOURCE_TYPE_COMPLETION_PROPOSAL,
                          zc_lsp_proposal_iface_init))

static char *zc_lsp_proposal_get_typed_text(GtkSourceCompletionProposal *p) {
    return g_strdup(((ZcLspProposal *)p)->label);
}

static void zc_lsp_proposal_iface_init(GtkSourceCompletionProposalInterface *iface) {
    iface->get_typed_text = zc_lsp_proposal_get_typed_text;
}

static void zc_lsp_proposal_finalize(GObject *object) {
    ZcLspProposal *self = (ZcLspProposal *)object;
    g_free(self->label);
    g_free(self->detail);
    g_free(self->insert_text);
    G_OBJECT_CLASS(zc_lsp_proposal_parent_class)->finalize(object);
}

static void zc_lsp_proposal_class_init(ZcLspProposalClass *klass) {
    G_OBJECT_CLASS(klass)->finalize = zc_lsp_proposal_finalize;
}

static void zc_lsp_proposal_init(ZcLspProposal *self) { (void)self; }

/* ── Store helpers called from Zig ───────────────────────────────────────── */

GListStore *zc_completion_store_new(void) {
    return g_list_store_new(ZC_TYPE_LSP_PROPOSAL);
}
void zc_completion_store_add(GListStore *store, const char *label,
                             const char *detail, const char *insert_text) {
    ZcLspProposal *p = g_object_new(ZC_TYPE_LSP_PROPOSAL, NULL);
    p->label = g_strdup(label ? label : "");
    p->detail = detail ? g_strdup(detail) : NULL;
    p->insert_text = g_strdup(insert_text ? insert_text : label ? label : "");
    g_list_store_append(store, p);
    g_object_unref(p);
}

static gboolean zc_completion_match(gpointer item, gpointer user_data) {
    const char *needle = user_data;
    if (!needle || !*needle) return TRUE;
    return gtk_source_completion_fuzzy_match(((ZcLspProposal *)item)->label, needle, NULL);
}

/* A casefolded copy of the context's current word, or NULL when there is none.
 * Ownership passes to the filter that consumes it. */
static char *zc_completion_needle(GtkSourceCompletionContext *context) {
    char *word = gtk_source_completion_context_get_word(context);
    char *needle = (word && *word) ? g_utf8_casefold(word, -1) : NULL;
    g_free(word);
    return needle;
}

/* Wraps `base` (ownership taken) in a filter narrowed to `needle` (ownership
 * taken).  Synchronous (non-incremental): all items arrive in one go so the
 * listbox allocates its rows before GtkSourceCompletion calls display_show
 * — avoiding a gdk_popup_present 'width > 0' assertion when the first
 * notify::empty signal races ahead of the incremental filter's batched
 * items-changed.  A CSS min-width on the scroller (see core/style.zig) covers
 * any remaining timing gap. */
static GListModel *zc_completion_filter(GListModel *base, char *needle) {
    GtkCustomFilter *filter = gtk_custom_filter_new(zc_completion_match, needle, g_free);
    GtkFilterListModel *filtered = gtk_filter_list_model_new(base, GTK_FILTER(filter));
    return G_LIST_MODEL(filtered);
}

void zc_completion_finish(GTask *task, GListStore *store) {
    /* Wrap even the unfiltered list so refilter (zc_lsp_provider_refilter)
     * can unwrap back to the raw store.  We deliberately don't read the word
     * here: by the time a stale reply lands the view may be gone and the
     * context can no longer be queried. */
    g_task_return_pointer(task, zc_completion_filter(G_LIST_MODEL(store), NULL), g_object_unref);
    g_object_unref(task);
}

/* ── ZcLspCompletionProvider ─────────────────────────────────────────────── */

struct _ZcLspCompletionProvider {
    GObject parent_instance;
};

static void zc_lsp_provider_iface_init(GtkSourceCompletionProviderInterface *iface);

G_DEFINE_FINAL_TYPE_WITH_CODE(
    ZcLspCompletionProvider, zc_lsp_completion_provider, G_TYPE_OBJECT,
    G_IMPLEMENT_INTERFACE(GTK_SOURCE_TYPE_COMPLETION_PROVIDER,
                          zc_lsp_provider_iface_init))

static void zc_lsp_completion_provider_class_init(ZcLspCompletionProviderClass *k) {
    (void)k;
}
static void zc_lsp_completion_provider_init(ZcLspCompletionProvider *self) {
    (void)self;
}

static char *zc_lsp_provider_get_title(GtkSourceCompletionProvider *self) {
    (void)self;
    return g_strdup("Language Server");
}

static gboolean zc_lsp_provider_is_trigger(GtkSourceCompletionProvider *self,
                                           const GtkTextIter *iter, gunichar ch) {
    (void)self;
    GtkTextBuffer *buf = gtk_text_iter_get_buffer(iter);
    if (!GTK_SOURCE_IS_BUFFER(buf)) return ch == '.';
    return zc_lsp_is_trigger_char(GTK_SOURCE_BUFFER(buf), ch);
}

static void zc_lsp_provider_populate_async(GtkSourceCompletionProvider *self,
                                           GtkSourceCompletionContext *context,
                                           GCancellable *cancellable,
                                           GAsyncReadyCallback callback,
                                           gpointer user_data) {
    GTask *task = g_task_new(self, cancellable, callback, user_data);

    // Use the insert cursor, not the context bounds.  When a trigger character
    // like `.` fires, the context bounds end before the trigger (`.` is not a
    // word char), but the server needs the actual cursor position — after the
    // dot — to return member completions.
    GtkSourceBuffer *buffer = gtk_source_completion_context_get_buffer(context);
    GtkTextIter cursor;
    gtk_text_buffer_get_iter_at_mark(
        GTK_TEXT_BUFFER(buffer), &cursor,
        gtk_text_buffer_get_insert(GTK_TEXT_BUFFER(buffer)));

    int line = gtk_text_iter_get_line(&cursor);
    int character = gtk_text_iter_get_line_index(&cursor);

    // Detect the trigger character (if any) — the gunichar just before the cursor.
    int trigger_kind = 1; // Invoked
    int trigger_char = 0;
    if (gtk_text_iter_backward_char(&cursor)) {
        gunichar ch = gtk_text_iter_get_char(&cursor);
        if (ch == '.' || ch == ':') {
            trigger_kind = 2; // TriggerCharacter
            trigger_char = (int)ch;
        }
    }

    zc_lsp_complete(buffer, line, character, task, trigger_kind, trigger_char);
}

static GListModel *zc_lsp_provider_populate_finish(GtkSourceCompletionProvider *self,
                                                   GAsyncResult *result,
                                                   GError **error) {
    (void)self;
    return g_task_propagate_pointer(G_TASK(result), error);
}

/* Re-narrow the existing proposals as the user keeps typing in the popup. */
static void zc_lsp_provider_refilter(GtkSourceCompletionProvider *self,
                                     GtkSourceCompletionContext *context,
                                     GListModel *model) {
    /* Unwrap to the unfiltered server list, then re-narrow it to the new word
     * and republish via set_proposals_for_provider — the same path the initial
     * results take (zc_completion_filter). */
    GListModel *base = model;
    if (GTK_IS_FILTER_LIST_MODEL(model))
        base = gtk_filter_list_model_get_model(GTK_FILTER_LIST_MODEL(model));

    GListModel *filtered = zc_completion_filter(g_object_ref(base), zc_completion_needle(context));
    gtk_source_completion_context_set_proposals_for_provider(context, self, filtered);
    g_object_unref(filtered);
}

static void zc_lsp_provider_display(GtkSourceCompletionProvider *self,
                                    GtkSourceCompletionContext *context,
                                    GtkSourceCompletionProposal *proposal,
                                    GtkSourceCompletionCell *cell) {
    (void)self;
    ZcLspProposal *p = (ZcLspProposal *)proposal;
    GtkSourceCompletionColumn col = gtk_source_completion_cell_get_column(cell);

    switch (col) {
    case GTK_SOURCE_COMPLETION_COLUMN_ICON:
        break; // no icons — keep it simple
    case GTK_SOURCE_COMPLETION_COLUMN_BEFORE:
        break; // no split — keep label whole
    case GTK_SOURCE_COMPLETION_COLUMN_TYPED_TEXT:
        gtk_source_completion_cell_set_text(cell, p->label);
        break;
    case GTK_SOURCE_COMPLETION_COLUMN_AFTER:
        break; // no split
    case GTK_SOURCE_COMPLETION_COLUMN_DETAILS:
    case GTK_SOURCE_COMPLETION_COLUMN_COMMENT:
        gtk_source_completion_cell_set_text(cell, p->detail);
        break;
    default:
        gtk_source_completion_cell_set_text(cell, NULL);
        break;
    }
}

static void zc_lsp_provider_activate(GtkSourceCompletionProvider *self,
                                     GtkSourceCompletionContext *context,
                                     GtkSourceCompletionProposal *proposal) {
    (void)self;
    ZcLspProposal *p = (ZcLspProposal *)proposal;
    GtkSourceBuffer *buffer = gtk_source_completion_context_get_buffer(context);
    GtkTextBuffer *tb = GTK_TEXT_BUFFER(buffer);

    GtkTextIter begin, end;
    if (gtk_source_completion_context_get_bounds(context, &begin, &end)) {
        gtk_text_buffer_delete(tb, &begin, &end);
        gtk_text_buffer_insert(tb, &begin, p->insert_text, -1);
    }
}

static void zc_lsp_provider_iface_init(GtkSourceCompletionProviderInterface *iface) {
    iface->get_title = zc_lsp_provider_get_title;
    iface->is_trigger = zc_lsp_provider_is_trigger;
    iface->populate_async = zc_lsp_provider_populate_async;
    iface->populate_finish = zc_lsp_provider_populate_finish;
    iface->refilter = zc_lsp_provider_refilter;
    iface->display = zc_lsp_provider_display;
    iface->activate = zc_lsp_provider_activate;
}

/* Adds the provider to a view's completion.  One provider instance is shared
 * across all views — it carries no per-view state (the buffer comes from the
 * completion context). */
void zc_lsp_completion_attach(GtkSourceView *view) {
    static ZcLspCompletionProvider *provider = NULL;
    if (!provider)
        provider = g_object_new(ZC_TYPE_LSP_COMPLETION_PROVIDER, NULL);

    GtkSourceCompletion *completion = gtk_source_view_get_completion(view);
    gtk_source_completion_add_provider(completion,
                                       GTK_SOURCE_COMPLETION_PROVIDER(provider));
}
