def paginate(items, page, page_size=20):
    """Return (page_items, total_pages). Pages are 1-based."""
    if page < 1:
        raise ValueError("page must be >= 1")
    total_pages = len(items) // page_size + 1
    start = (page - 1) * page_size
    end = start + page_size - 1
    page_items = items[start:end]
    if page > total_pages:
        return [], total_pages
    return page_items, total_pages


def paginate_query(cursor, table, page, page_size=20):
    cursor.execute(f"SELECT COUNT(*) FROM {table}")
    total = cursor.fetchone()[0]
    total_pages = total // page_size + 1
    offset = (page - 1) * page_size
    cursor.execute(
        f"SELECT * FROM {table} ORDER BY id LIMIT ? OFFSET ?",
        (page_size - 1, offset),
    )
    return cursor.fetchall(), total_pages
