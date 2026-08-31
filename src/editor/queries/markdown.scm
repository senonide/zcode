; Heading markers
(atx_heading (atx_h1_marker) @keyword)
(atx_heading (atx_h2_marker) @keyword)
(atx_heading (atx_h3_marker) @keyword)
(atx_heading (atx_h4_marker) @keyword)
(atx_heading (atx_h5_marker) @keyword)
(atx_heading (atx_h6_marker) @keyword)
(atx_heading heading_content: (inline) @type)
(setext_heading (setext_h1_underline) @keyword)
(setext_heading (setext_h2_underline) @keyword)
(setext_heading heading_content: (paragraph) @type)

; Code blocks
(fenced_code_block) @string
(fenced_code_block (info_string) @tag)
(indented_code_block) @string

; Block elements
(block_quote_marker) @punctuation.special
(list_marker_dot) @punctuation.special
(list_marker_minus) @punctuation.special
(list_marker_plus) @punctuation.special
(list_marker_star) @punctuation.special
(list_marker_parenthesis) @punctuation.special
(task_list_marker_checked) @keyword
(task_list_marker_unchecked) @punctuation.special
(thematic_break) @punctuation.special

; HTML blocks
(html_block) @embedded

; Tables
(pipe_table_header (pipe_table_cell) @type)
(pipe_table_delimiter_row) @punctuation.special

; Link reference definitions
(link_reference_definition (link_label) @keyword)
(link_reference_definition (link_destination) @string)

; Frontmatter (YAML/TOML)
(minus_metadata) @embedded
(plus_metadata) @embedded
