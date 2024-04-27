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

  if (data.debug.type == "k_means") {
    for (let mean_idx in data.debug.means) {
      const mean = data.debug.means[mean_idx];
      const color = cluster_colors[mean_idx];
      ctx.lineWidth = 10;
      ctx.strokeStyle = "black";
      ctx.fillStyle = color;
      const rect_size = 20;
      ctx.fillRect(
        mean.x * canvas_scale + canvas_offset - rect_size / 2,
        mean.y * canvas_scale + canvas_offset - rect_size / 2,
        rect_size,
        rect_size,
      );
      ctx.beginPath();
      ctx.rect(
        mean.x * canvas_scale + canvas_offset - rect_size / 2,
        mean.y * canvas_scale + canvas_offset - rect_size / 2,
        rect_size,
        rect_size,
      );
      ctx.stroke();
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

async function setClusterer(value) {
  await fetch("/set_clusterer?id=" + value);
  await rerender();
}

async function populateClusterers() {
  const clusterers_response = await fetch("/clusterers");
  const clusterers = await clusterers_response.json();

  /** @type HTMLSelectElement */
  const clusterers_select = document.getElementById("clusterer");
  for (let clusterer of clusterers) {
    const option = document.createElement("option");
    option.text = clusterer.name;
    option.value = clusterer.id;
    clusterers_select.add(option);
  }
  clusterers_select.addEventListener("change", async function (ev) {
    setClusterer(ev.target.value);
  });

  setClusterer(clusterers_select.value);
}

window.onload = async function () {
  populateClusterers();

  const next_button = document.getElementById("next");
  next_button.onclick = next;
  const reset_button = document.getElementById("reset");
  reset_button.onclick = reset;
  rerender();
};
