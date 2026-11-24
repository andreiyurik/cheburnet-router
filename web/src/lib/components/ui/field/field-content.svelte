<script>
	import { cn } from "$lib/utils.js";

	let {
		ref = $bindable(null),
		class: className,
		children,
		...restProps
	} = $props();
</script>

<div
	bind:this={ref}
	data-slot="field-content"
	class={cn("group/field-content flex flex-1 flex-col gap-1.5 leading-snug", className)}
	{...restProps}
>
	{@render children?.()}
</div>
