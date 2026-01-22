import networkx as nx
import queue
from collections import defaultdict

# PIPELINE 1: Dijkstra Standard
def standard_dijkstra(g, s, t, weight_attr):
    try:
        return nx.shortest_path_length(g, s, t, weight=weight_attr)
    except nx.NetworkXNoPath:
        return float("inf")

# PIPELINE 2: Dijkstra Bidirezionale (Corretto)
def bidirectional_dijkstra(g, s, t, weight_func):
    if s == t:
        return 0

    df = defaultdict(lambda: float("inf"))
    df[s] = 0
    db = defaultdict(lambda: float("inf"))
    db[t] = 0

    fq = queue.PriorityQueue()
    fq.put((0, s))
    bq = queue.PriorityQueue()
    bq.put((0, t))

    mu = float("inf")
    sf, sb = set(), set()
    u, v = s, t

    while not fq.empty() and not bq.empty():
        if df[u] + db[v] >= mu:
            return mu

        # Forward search
        if not fq.empty():
            _, u = fq.get()
            if u not in sf:
                sf.add(u)
                for x in g.adj[u]:
                    w = weight_func(u, x) # Usa direttamente la funzione passata
                    if df[x] > df[u] + w:
                        df[x] = df[u] + w
                        fq.put((df[x], x))
                    if x in sb and df[u] + w + db[x] < mu:
                        mu = df[u] + w + db[x]

        # Backward search
        if not bq.empty():
            _, v = bq.get()
            if v not in sb:
                sb.add(v)
                for x in g.adj[v]:
                    w = weight_func(v, x)
                    if db[x] > db[v] + w:
                        db[x] = db[v] + w
                        bq.put((db[x], x))
                    if x in sf and db[v] + w + df[x] < mu:
                        mu = db[v] + w + df[x]

    return mu if mu != float("inf") else float("inf")