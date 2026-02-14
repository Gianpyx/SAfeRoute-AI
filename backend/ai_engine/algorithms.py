import queue

import networkx as nx


# PIPELINE 1: Dijkstra Standard
def standard_dijkstra(g, s, t, weight_attr):
    try:
        dist = nx.shortest_path_length(g, s, t, weight=weight_attr)
        path = nx.shortest_path(g, s, t, weight=weight_attr)
        return dist, path
    except nx.NetworkXNoPath:
        return float("inf"), []

# PIPELINE 2: Dijkstra Bidirezionale (Corretto)
def bidirectional_dijkstra(g, s, t, weight_func):
    if s == t: return 0, [s]
    df, db = {s: 0}, {t: 0}
    fq, bq = queue.PriorityQueue(), queue.PriorityQueue()
    fq.put((0, s))
    bq.put((0, t))
    parent_f, parent_b = {s: None}, {t: None}
    mu = float("inf")
    meeting_node = None
    sf, sb = set(), set()

    while not fq.empty() and not bq.empty():
        # Condizione di stop: la somma dei minimi delle code supera la soluzione migliore trovata
        if fq.queue[0][0] + bq.queue[0][0] >= mu: break

        # Forward search
        _, u = fq.get()
        if u not in sf:
            sf.add(u)
            for x in g.adj[u]:
                w = weight_func(u, x)
                if df.get(x, float('inf')) > df[u] + w:
                    df[x] = df[u] + w
                    parent_f[x] = u
                    fq.put((df[x], x))
                if x in db and df[x] + db[x] < mu:
                    mu = df[x] + db[x]
                    meeting_node = x

        # Backward search
        _, v = bq.get()
        if v not in sb:
            sb.add(v)
            for x in g.adj[v]:
                w = weight_func(v, x)
                if db.get(x, float('inf')) > db[v] + w:
                    db[x] = db[v] + w
                    parent_b[x] = v
                    bq.put((db[x], x))
                if x in df and db[x] + df[x] < mu:
                    mu = db[x] + df[x]
                    meeting_node = x

    if meeting_node is None: return float("inf"), []

    # Ricostruzione percorso
    path = []
    curr = meeting_node
    while curr is not None:
        path.append(curr)
        curr = parent_f[curr]
    path.reverse()
    curr = parent_b[meeting_node]
    while curr is not None:
        path.append(curr)
        curr = parent_b[curr]
    return mu, path,
