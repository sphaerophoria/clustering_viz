var cluster_colors = [];
var data = null;
const canvas_scale = 7;
const canvas_offset = 25;

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

function renderPoint(ctx, point, color, canvas_scale, canvas_offset) {
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

async function rerender() {
  const response = await fetch("/data");
  data = await response.json();
  if (cluster_colors.length !== data.clusters.length) {
    resetClusterColors(data.clusters.length);
  }
  /** @type HTMLCanvasElement */
  const canvas = document.getElementById("canvas");
  const ctx = canvas.getContext("2d");
  ctx.clearRect(0, 0, canvas.width, canvas.height);

  for (const point of data.points) {
    renderPoint(ctx, point, "black", canvas_scale, canvas_offset);
  }

  for (let cluster_id = 0; cluster_id < data.clusters.length; cluster_id++) {
    const color = cluster_colors[cluster_id];
    for (const point_id of data.clusters[cluster_id]) {
      const point = data.points[point_id];
      renderPoint(ctx, point, color, canvas_scale, canvas_offset);
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

  if (data.debug.type == "ap") {
    document.getElementById("ap_debug").style.display = "";
    const point_selector = document.getElementById("ap_point_selector");
    point_selector.max = data.points.length - 1;
    if (point_selector.value > point_selector.max) {
      point_selector.value = point_selector.max;
    }
    var event = new Event("input", {
      bubbles: true,
    });

    point_selector.dispatchEvent(event);
    rerenderApDebug();
  } else {
    document.getElementById("ap_debug").style.display = "none";
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

async function setClusterer() {
  const clusterer = document.getElementById("clusterer").value;
  const num_means = document.getElementById("num_means").value;
  const eps = document.getElementById("eps").value;
  const min_pts = document.getElementById("min_pts").value;
  await fetch(
    "/set_clusterer?id=" +
      clusterer +
      "&num_means=" +
      num_means +
      "&eps=" +
      eps +
      "&min_pts=" +
      min_pts,
  );
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
  clusterers_select.onchange = setClusterer;
  document.getElementById("num_means").onchange = setClusterer;
  document.getElementById("eps").onchange = setClusterer;
  document.getElementById("min_pts").onchange = setClusterer;

  setClusterer();
}

async function renderApDebugCanvas(canvas, debug_elems) {
  const selected_point = document.getElementById("ap_point_selector").value;

  const canvas_ctx = canvas.getContext("2d");
  canvas_ctx.clearRect(0, 0, canvas.width, canvas.height);
  canvas_ctx.clearRect(0, 0, canvas.width, canvas.height);

  renderPoint(
    canvas_ctx,
    data.points[selected_point],
    "yellow",
    canvas_scale,
    canvas_offset,
  );

  const start_idx = selected_point * data.points.length;
  const end_idx = start_idx + data.points.length;
  const elems_by_point = debug_elems.slice(start_idx, end_idx);

  const max_availability = Math.max.apply(null, elems_by_point);
  const min_availability = Math.min.apply(null, elems_by_point);
  const max_magnitude = Math.max(
    Math.abs(min_availability),
    Math.abs(max_availability),
  );

  for (let point_id = 0; point_id < data.points.length; point_id++) {
    if (point_id == selected_point) {
      continue;
    }
    const point = data.points[point_id];

    const item_norm = elems_by_point[point_id] / max_magnitude;

    var color = "";
    if (item_norm > 0) {
      color = "rgb(0, " + Math.floor(item_norm * 255) + ", 0)";
    } else {
      color = "rgb(" + Math.floor(-item_norm * 255) + ", 0, 0)";
    }

    renderPoint(canvas_ctx, point, color, canvas_scale, canvas_offset);
  }
}

async function rerenderApDebug() {
  if (data.debug.type != "ap") {
    return;
  }

  const availability_canvas = document.getElementById("availability_canvas");
  renderApDebugCanvas(availability_canvas, data.debug.availability);
  const responsibility_canvas = document.getElementById(
    "responsibility_canvas",
  );
  renderApDebugCanvas(responsibility_canvas, data.debug.responsibility);
}

window.onload = async function () {
  populateClusterers();

  document.getElementById("ap_point_selector").oninput = function (ev) {
    document.getElementById("ap_point_val").innerHTML = ev.target.value;
    rerenderApDebug();
  };

  const next_button = document.getElementById("next");
  next_button.onclick = next;
  const reset_button = document.getElementById("reset");
  reset_button.onclick = reset;
  rerender();
};
