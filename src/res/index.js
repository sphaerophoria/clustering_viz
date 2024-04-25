var cluster_colors = [];

// Clusters can have some initial structure, which results in similar positions
// naturally having similar colors if we just map cluster id to hue. We store
// cluster colors and randomize the order to ensure a random distribution
function resetClusterColors(num_clusters) {
  cluster_colors = [];
  for (let i = 0; i < num_clusters; i++) {
    const hue = (i / num_clusters) * 360;
    cluster_colors.push("hsla(" + Math.floor(hue) + ", 100%, 50%, 1.0)");
  }

  // Yoinked from stack overflow but makes sense
  cluster_colors = cluster_colors
    .map((value) => ({ value, sort: Math.random() }))
    .sort((a, b) => a.sort - b.sort)
    .map(({ value }) => value);
}

async function rerender() {
  const response = await fetch("/data");
  const data = await response.json();
  if (cluster_colors.length !== data.clusters.length) {
    resetClusterColors(data.clusters.length);
  }
  /** @type HTMLCanvasElement */
  const canvas = document.getElementById("canvas");
  const ctx = canvas.getContext("2d");
  ctx.clearRect(0, 0, canvas.width, canvas.height);

  const canvas_scale = 7;
  const canvas_offset = 25;

  for (let cluster_id = 0; cluster_id < data.clusters.length; cluster_id++) {
    const color = cluster_colors[cluster_id];
    for (const point_id of data.clusters[cluster_id]) {
      const point = data.points[point_id];
      ctx.beginPath();
      ctx.arc(
        point.x * canvas_scale + canvas_offset,
        point.y * canvas_scale + canvas_offset,
        10,
        0,
        2 * Math.PI,
      );
      ctx.fillStyle = color;
      ctx.fill();
    }
  }
}

async function next() {
  const num_steps = document.getElementById("step-size").value;
  for (let i = 0; i < num_steps; i++) {
    await fetch("/next");
  }
  await rerender();
}

async function reset() {
  const num_elems = document.getElementById("num-elems").value;
  const num_clusters = document.getElementById("num-clusters").value;
  const cluster_radius = document.getElementById("cluster-radius").value;
  await fetch(
    "/reset?num_elems=" +
      num_elems +
      "&num_clusters=" +
      num_clusters +
      "&cluster_radius=" +
      cluster_radius,
  );
  await rerender();
}

window.onload = async function () {
  const next_button = document.getElementById("next");
  next_button.onclick = next;
  const reset_button = document.getElementById("reset");
  reset_button.onclick = reset;
  rerender();
};
